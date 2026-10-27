`timescale 1ns/1ps
// 验证 bmp_read：行尾 4 字节对齐填充跳过、宽度/高度保护、提前结束
module tb_bmp_stride;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;   // 100MHz

    reg        scan_start = 0, load_start = 0, load_abort = 0;
    reg [31:0] scan_start_sector = 0, scan_max_sector = 0;
    reg [4:0]  scan_target_count = 1;
    reg [31:0] load_sector = 0;
    reg        sd_init_done = 1;
    reg        i_stall = 0;

    wire        ready, scan_done, scan_found_valid, wav_found;
    wire [31:0] scan_found_sector, wav_start_sector;
    wire [4:0]  scan_found_total;
    wire [3:0]  state_code;
    wire [15:0] src_width, src_height;
    wire        write_req, sd_sec_read;
    wire [31:0] sd_sec_read_addr;
    reg  [7:0]  sd_sec_read_data;
    reg         sd_sec_read_data_valid;
    reg         sd_sec_read_end;
    wire        bmp_data_wr_en;
    wire [23:0] bmp_data;

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
        .src_width(src_width), .src_height(src_height), .i_stall(i_stall),
        .write_req(write_req), .write_req_ack(1'b1),
        .sd_sec_read(sd_sec_read), .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .bmp_data_wr_en(bmp_data_wr_en), .bmp_data(bmp_data)
    );

    // ---- 4 扇区假 SD 卡 ----
    reg [7:0] mem [0:2047];
    integer i;
    integer pix_count;
    reg [23:0] pix_got [0:15];

    always @(posedge clk) begin
        if (bmp_data_wr_en) begin
            pix_got[pix_count] <= bmp_data;
            pix_count <= pix_count + 1;
        end
    end

    // ---- 扇区响应器：512 字节 + 1 拍 read_end ----
    localparam R_IDLE = 2'd0, R_DATA = 2'd1, R_WAIT = 2'd2, R_NEXT = 2'd3;
    reg [1:0]  rstate;
    reg [9:0]  rd_idx;
    reg [31:0] rd_addr;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            rstate <= R_IDLE;
            rd_idx <= 10'd0;
            rd_addr <= 32'd0;
            sd_sec_read_data <= 8'd0;
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end <= 1'b0;
        end else begin
            sd_sec_read_data_valid <= 1'b0;
            sd_sec_read_end <= 1'b0;
            case (rstate)
                R_IDLE: if (sd_sec_read) begin
                    rd_idx  <= 10'd0;
                    rd_addr <= sd_sec_read_addr;
                    rstate  <= R_DATA;
                end
                R_DATA: begin
                    if (rd_idx < 10'd512) begin
                        sd_sec_read_data <= mem[{rd_addr[1:0], rd_idx[8:0]}];
                        sd_sec_read_data_valid <= 1'b1;
                        rd_idx <= rd_idx + 10'd1;
                    end else begin
                        sd_sec_read_end <= 1'b1;
                        rstate <= R_WAIT;
                    end
                end
                R_WAIT: rstate <= R_NEXT;   // read_end 生效拍，地址尚未更新
                R_NEXT: begin               // DUT 已更新地址（或撤销读请求）
                    if (sd_sec_read) begin
                        rd_idx  <= 10'd0;
                        rd_addr <= sd_sec_read_addr;
                        rstate  <= R_DATA;
                    end else begin
                        rstate <= R_IDLE;
                    end
                end
            endcase
        end
    end

    task set_u32(input integer off, input [31:0] v);
        begin
            mem[off]     = v[7:0];
            mem[off + 1] = v[15:8];
            mem[off + 2] = v[23:16];
            mem[off + 3] = v[31:24];
        end
    endtask

    // 24bit BMP：宽 w、高 h（可为负数）、行填充字节 pad
    task build_bmp(input integer w, input integer h, input [7:0] pad);
        integer row, col, po;
        begin
            for (i = 0; i < 2048; i = i + 1) mem[i] = 8'h00;
            mem[0] = "B"; mem[1] = "M";
            set_u32(2,  32'd78);        // file_len
            set_u32(10, 32'd54);        // pixel_offset
            set_u32(14, 32'd40);        // DIB size
            set_u32(18, w);
            set_u32(22, h);
            mem[26] = 8'd1; mem[27] = 8'd0;
            mem[28] = 8'd24; mem[29] = 8'd0;
            set_u32(30, 32'd0);         // compression
            set_u32(34, w * h * 3);
            po = 54;
            // 底行在前；像素值刻意取 (行*3+列) 便于识别
            for (row = 0; row < 2; row = row + 1) begin
                for (col = 0; col < w; col = col + 1) begin
                    mem[po]     = row * w * 3 + col * 3 + 3;  // B
                    mem[po + 1] = row * w * 3 + col * 3 + 2;  // G
                    mem[po + 2] = row * w * 3 + col * 3 + 1;  // R
                    po = po + 3;
                end
                while ((po - 54) % 4 != 0) begin
                    mem[po] = pad;
                    po = po + 1;
                end
            end
        end
    endtask

    task do_reset;
        begin
            rst = 1;
            scan_start = 0; load_start = 0;
            repeat (10) @(posedge clk);
            rst = 0;
            repeat (5) @(posedge clk);
        end
    endtask

    task wait_ready;
        integer t;
        begin
            t = 0;
            while (!ready && t < 100000) begin
                @(posedge clk);
                t = t + 1;
            end
            if (t >= 100000) $display(">>> TIMEOUT waiting ready");
        end
    endtask

    integer errors = 0;

    initial begin
        pix_count = 0;

        // ================= case 1: width=3 height=2, 行填充 3 字节 =================
        do_reset;
        build_bmp(3, 2, 8'hAA);
        pix_count = 0;
        @(posedge clk); scan_start = 1; @(posedge clk); scan_start = 0;
        wait (scan_done);
        repeat (2) @(posedge clk);
        $display("case1 scan: total=%0d sector=%0d", scan_found_total, scan_found_sector);
        if (scan_found_total !== 5'd1 || scan_found_sector !== 32'd0) begin
            errors = errors + 1; $display(">>> BUG case1 scan");
        end
        @(negedge clk); load_start = 1;
        @(negedge clk); load_start = 0;
        repeat (20) @(posedge clk);
        $display("case1 after load pulse: state=%0d ready=%b sd_read=%b addr=%0d",
                 dut.state, ready, sd_sec_read, sd_sec_read_addr);
        wait_ready;
        repeat (5) @(posedge clk);
        $display("case1 load: w=%0d h=%0d pixels=%0d", src_width, src_height, pix_count);
        for (i = 0; i < pix_count; i = i + 1)
            $display("  pix[%0d]=%06h", i, pix_got[i]);
        if (pix_count !== 6) begin
            errors = errors + 1; $display(">>> BUG case1 pixel count (padding not skipped?)");
        end else begin
            if (pix_got[0] !== 24'h010203 || pix_got[2] !== 24'h070809 ||
                pix_got[3] !== 24'h0A0B0C || pix_got[5] !== 24'h101112) begin
                errors = errors + 1; $display(">>> BUG case1 pixel value");
            end
        end

        // ================= case 2: 负高度（自顶向下）应被拒绝 =================
        do_reset;
        build_bmp(3, -2, 8'hAA);
        pix_count = 0;
        scan_target_count = 1; scan_max_sector = 0;
        @(posedge clk); scan_start = 1; @(posedge clk); scan_start = 0;
        wait (scan_done);
        repeat (2) @(posedge clk);
        $display("case2 scan: total=%0d", scan_found_total);
        if (scan_found_total !== 5'd0) begin
            errors = errors + 1; $display(">>> BUG case2 negative height accepted");
        end
        @(posedge clk); load_start = 1; @(posedge clk); load_start = 0;
        wait_ready;
        repeat (5) @(posedge clk);
        if (pix_count !== 0) begin
            errors = errors + 1; $display(">>> BUG case2 pixels emitted=%0d", pix_count);
        end

        // ================= case 3: 宽度 1025 超限应被拒绝 =================
        do_reset;
        build_bmp(3, 2, 8'hAA);
        set_u32(18, 32'd1025);
        pix_count = 0;
        @(posedge clk); scan_start = 1; @(posedge clk); scan_start = 0;
        wait (scan_done);
        repeat (2) @(posedge clk);
        $display("case3 scan: total=%0d", scan_found_total);
        if (scan_found_total !== 5'd0) begin
            errors = errors + 1; $display(">>> BUG case3 width 1025 accepted");
        end

        // ================= case 4: width=4 无填充（回归）=================
        do_reset;
        build_bmp(4, 2, 8'hAA);
        pix_count = 0;
        @(posedge clk); scan_start = 1; @(posedge clk); scan_start = 0;
        wait (scan_done);
        repeat (2) @(posedge clk);
        @(negedge clk); load_start = 1;
        @(negedge clk); load_start = 0;
        wait_ready;
        repeat (5) @(posedge clk);
        $display("case4 load: pixels=%0d first=%06h last=%06h", pix_count, pix_got[0], pix_got[7]);
        if (pix_count !== 8 || pix_got[0] !== 24'h010203 || pix_got[7] !== 24'h161718) begin
            errors = errors + 1; $display(">>> BUG case4 no-padding regression");
        end

        if (errors == 0) $display(">>> PASS: bmp stride/size guard");
        else             $display(">>> FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display(">>> TIMEOUT global");
        $finish;
    end
endmodule
