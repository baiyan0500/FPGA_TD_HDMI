`timescale 1ns/1ps
// tb_e2e_video — 真实卡数据端到端：egv_reader -> video_frame_fill -> 写口字流
//
// SD 模型：单段容器，LBA=1000（头），数据 1001 起 201 扇区来自 e2e_blk.hex
//          （tools/video 导出的卡上第 100 帧原始块）
// 输出：wr_en && !addr_full 时的 32bit 字，逐行写入 e2e_out.txt
//       供 Python 与 e2e_exp.hex（期望 2 倍放大 640x296）比对
module tb_e2e_video;
    localparam integer BLOCK = 201;
    localparam integer FW = 307200;      // FULL_WORDS
    localparam integer VW = 189440;      // VIDEO_WORDS
    localparam [31:0]  HDR_LBA = 32'd1000;

    reg clk = 0, rst = 1;
    reg play = 0;
    always #5 clk = ~clk;

    // ---------------- DUT: egv_reader ----------------
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

    wire        wr_req, wr_en, wr_ack;
    wire [31:0] wr_data;
    wire [20:0] wr_len;
    wire        wr_bank, addr_full, disp_bank, ready, busy, frame_end, frame_ready;

    egv_reader #(.FRAME_CYC(23'd2000)) dut_rd (
        .clk(clk), .rst(rst), .i_play(play), .i_sd_ready(1'b1),
        .i_fill_ready(frame_ready),
        .i_scan_done(1'b1), .i_egv_found(1'b1), .i_egv_lba(HDR_LBA),
        .o_sd_read(o_sd_read), .o_sd_addr(o_sd_addr), .o_sd_count(o_sd_count),
        .i_sd_data(i_sd_data), .i_sd_data_valid(i_sd_data_valid),
        .i_sd_read_end(i_sd_read_end),
        .o_pix_en(o_pix_en), .o_pix(o_pix), .o_frame_start(o_frame_start),
        .o_aud_en(o_aud_en), .o_aud_byte(o_aud_byte), .o_aud_fstart(o_aud_fstart),
        .o_frame_no(o_frame_no), .o_active(o_active)
    );

    video_frame_fill dut_fill (
        .clk(clk), .rst(rst), .i_en(1'b1),
        .i_frame_start(o_frame_start), .i_pix_en(o_pix_en), .i_pix(o_pix),
        .o_wr_req(wr_req), .i_wr_ack(wr_ack), .o_wr_en(wr_en),
        .o_wr_data(wr_data), .o_wr_len(wr_len), .o_wr_bank(wr_bank),
        .o_addr_full(addr_full), .i_fin_tgl(1'b0),
        .o_disp_bank(disp_bank), .o_ready(ready), .o_busy(busy),
        .o_frame_end(frame_end), .o_frame_ready(frame_ready)
    );

    // 写应答：延迟 3 拍，同时撤销 req
    reg [1:0] ack_cnt;
    assign wr_ack = (ack_cnt == 2'd3);
    always @(posedge clk or posedge rst) begin
        if (rst) ack_cnt <= 2'd0;
        else if (wr_ack) ack_cnt <= 2'd0;
        else if (wr_req) ack_cnt <= ack_cnt + 2'd1;
    end

    // ---------------- SD 扇区模型 ----------------
    reg [7:0] blk [0:201*512-1];
    reg [7:0] hdr [0:511];
    integer i, fd;
    initial begin
        $readmemh("e2e_blk.hex", blk);
        // 单段合法头
        for (i = 0; i < 512; i = i + 1) hdr[i] = 8'd0;
        hdr[0]="E"; hdr[1]="G"; hdr[2]="V"; hdr[3]="1";
        hdr[4]=8'd2; hdr[5]=8'd0;
        hdr[6]=8'd64;  hdr[7]=8'd1;      // 320
        hdr[8]=8'd148; hdr[9]=8'd0;      // 148
        hdr[10]=8'd24; hdr[11]=8'd0;     // fps
        hdr[12]=8'd1;  hdr[13]=8'd0; hdr[14]=8'd0; hdr[15]=8'd0;   // frames=1
        hdr[16]=8'd0;  hdr[17]=8'd0; hdr[18]=8'd0; hdr[19]=8'd0;   // block_bytes(不校验)
        hdr[20]=8'd0;  hdr[21]=8'd0; hdr[22]=8'd0; hdr[23]=8'd0;   // 占位，稍后写
        // video_bytes = 94720 = 0x17200
        hdr[20]=8'h00; hdr[21]=8'h72; hdr[22]=8'h01; hdr[23]=8'h00;
        // audio_bytes = 8000 = 0x1F40
        hdr[24]=8'h40; hdr[25]=8'h1F; hdr[26]=8'd0; hdr[27]=8'd0;
        // arate=48000
        hdr[28]=8'h80; hdr[29]=8'hBB;
        hdr[30]=8'd2; hdr[31]=8'd0;      // ach=2
        hdr[32]=8'd201; hdr[33]=8'd0;    // block_sectors
        hdr[34]=8'd12;  hdr[35]=8'd0;    // audio_mod
        hdr[40]=8'd1;  hdr[41]=8'd0;     // n_runs=1
        // run0: logical=0, nsec=202, phys=1000
        hdr[44]=0; hdr[45]=0; hdr[46]=0; hdr[47]=0;
        hdr[48]=8'd202; hdr[49]=8'd0; hdr[50]=0; hdr[51]=0;
        hdr[52]=8'hE8; hdr[53]=8'h03; hdr[54]=0; hdr[55]=0;   // 1000
    end

    reg [31:0] cur;
    reg [8:0]  bcnt;
    reg        busy_s, started;
    reg [15:0] bleft;
    reg        in_hdr;
    reg [5:0]  gap;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            i_sd_data_valid <= 1'b0; i_sd_read_end <= 1'b0;
            busy_s <= 1'b0; started <= 1'b0; bcnt <= 9'd0;
            bleft <= 16'd0; cur <= 32'd0; in_hdr <= 1'b0; gap <= 6'd0;
        end else begin
            i_sd_data_valid <= 1'b0;
            i_sd_read_end   <= 1'b0;
            if (!o_sd_read) begin
                busy_s <= 1'b0; started <= 1'b0; bcnt <= 9'd0; bleft <= 16'd0;
            end else if (!busy_s) begin
                busy_s <= 1'b1; started <= 1'b0;
            end else if (!started) begin
                started <= 1'b1; bcnt <= 9'd0;
                if (bleft == 16'd0) begin
                    cur   <= o_sd_addr;
                    bleft <= o_sd_count - 16'd1;
                    if (o_sd_addr == HDR_LBA) in_hdr <= 1'b1;
                    else                      in_hdr <= 1'b0;
                end else begin
                    cur   <= cur + 32'd1;
                    bleft <= bleft - 16'd1;
                end
            end else if (gap != 6'd0) begin
                // 真实 SPI 25MHz：每字节 32 个 100MHz 拍（3.125MB/s）
                gap <= gap - 6'd1;
            end else begin
                i_sd_data       <= (cur == HDR_LBA) ? hdr[bcnt]
                                                    : blk[(cur - (HDR_LBA + 32'd1)) * 512 + bcnt];
                i_sd_data_valid <= 1'b1;
                gap             <= 6'd31;
                if (bcnt == 9'd511) begin
                    bcnt <= 9'd0; busy_s <= 1'b0; started <= 1'b0;
                    i_sd_read_end <= 1'b1;
                end else
                    bcnt <= bcnt + 9'd1;
            end
        end
    end

    // ---------------- 捕获写口字流 ----------------
    integer wcnt = 0, pcnt = 0, acnt = 0;
    integer afd, pfd;
    initial afd = $fopen("e2e_aud.txt", "w");
    initial pfd = $fopen("e2e_pix.txt", "w");
    always @(posedge clk) begin
        if (!rst && o_pix_en) begin
            $fdisplay(pfd, "%04x", o_pix);
            pcnt = pcnt + 1;
        end
        if (!rst && o_aud_en) begin
            $fdisplay(afd, "%02x", o_aud_byte);
            acnt = acnt + 1;
        end
        if (!rst && wr_en && !addr_full) begin
            $fdisplay(fd, "%08x", wr_data);
            wcnt = wcnt + 1;
        end
    end

    integer efail = 0;
    initial begin
        fd = $fopen("e2e_out.txt", "w");
        rst = 1;
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (5) @(posedge clk);
        play = 1;
        wait (wcnt == VW);
        repeat (200) @(posedge clk);
        $fclose(fd);
        $fclose(afd);
        $fclose(pfd);
        $display("E2E DONE: words=%0d pix=%0d aud=%0d frames=%0d active=%b",
                 wcnt, pcnt, acnt, o_frame_no, o_active);
        if (wcnt != VW) begin $display("E2E FAIL word count %0d != %0d", wcnt, VW); efail = efail + 1; end
        // LOOP_PLAY=1 时会紧接下一帧，像素数可略多于 320*148，只要求覆盖满一帧
        if (pcnt < 320*148) begin $display("E2E FAIL pix count %0d", pcnt); efail = efail + 1; end
        if (acnt < 8000) begin $display("E2E FAIL aud count %0d", acnt); efail = efail + 1; end
        if (efail == 0) $display("TB_E2E_VIDEO PASS");
        else           $display("TB_E2E_VIDEO FAIL %0d", efail);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("E2E TIMEOUT words=%0d pix=%0d aud=%0d", wcnt, pcnt, acnt);
        $finish;
    end
endmodule
