// tb_real_reader — 用卡上真实容器头 + 真实段表驱动 egv_reader
//
// 目的：验证运行时段表解析、物理地址推进、跨段跳转、音频扇区相位
//       是否与"已验证正确的 Python 复现"逐像素一致。
// 激励：real_mem.hex = 卡上 F:/VIDEO.EGV 前 416 个扇区的原始字节
// 期望：real_exp_pix.hex = 前 2 帧共 94720 个 RGB565 像素
`timescale 1ns/1ps
module tb_real_reader;

    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;

    // 卡上文件前 416 扇区
    reg [7:0] mem [0:212991];
    initial $readmemh("real_mem.hex", mem);

    // 期望像素
    reg [15:0] exp_pix [0:94719];

    reg        i_play = 1;
    reg        i_sd_ready = 1;
    reg        i_fill_ready = 1;
    reg        i_scan_done = 1;
    reg        i_egv_found = 1;
    reg [31:0] i_egv_lba = 32'd47360;

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

    egv_reader #(
        .FRAME_CYC (23'd200_000),
        .LOOP_PLAY (1)
    ) dut (
        .clk           (clk),
        .rst           (rst),
        .i_play        (i_play),
        .i_sd_ready    (i_sd_ready),
        .i_fill_ready  (i_fill_ready),
        .i_scan_done   (i_scan_done),
        .i_egv_found   (i_egv_found),
        .i_egv_lba     (i_egv_lba),
        .o_sd_read     (o_sd_read),
        .o_sd_addr     (o_sd_addr),
        .o_sd_count    (o_sd_count),
        .i_sd_data     (i_sd_data),
        .i_sd_data_valid (i_sd_data_valid),
        .i_sd_read_end (i_sd_read_end),
        .o_pix_en      (o_pix_en),
        .o_pix         (o_pix),
        .o_frame_start (o_frame_start),
        .o_aud_en      (o_aud_en),
        .o_aud_byte    (o_aud_byte),
        .o_aud_fstart  (o_aud_fstart),
        .o_frame_no    (o_frame_no),
        .o_active      (o_active)
    );

    // ---------------- 卡上 LBA -> 文件内扇区偏移 ----------------
    function [31:0] memoff;
        input [31:0] lba;
        begin
            if (lba == 32'd47360)                    memoff = 32'd0;
            else if (lba >= 32'd47361 && lba <= 32'd47615) memoff = lba - 32'd47360;
            else if (lba >= 32'd513280)              memoff = 32'd256 + (lba - 32'd513280);
            else                                     memoff = 32'd0;
        end
    endfunction

    // ---------------- SD 卡模型（25MHz SPI = 每字节 32 拍）----------------
    // 必须按真实读核语义实现 CMD18：sd_sec_read 保持高电平期间一次读完
    // o_sd_count 个**物理连续**扇区，每扇区结束时给一拍 read_end；
    // 读核在最后一块的 read_end 之后 4 拍才重新采样 sd_sec_read/地址/批长，
    // 所以模型在批结束后留几拍空隙再回 M_IDLE（对应 S_READ_END/WAIT/WAIT2）。
    localparam [2:0] M_IDLE = 3'd0, M_LOCK = 3'd1, M_DATA = 3'd2, M_END = 3'd3,
                     M_GAP = 3'd4, M_NEXT = 3'd5;
    reg [2:0]  sst = M_IDLE;
    reg [31:0] caddr;
    reg [15:0] bcnt;
    reg [15:0] left;      // 本批剩余扇区数（含当前扇区）
    reg [7:0]  gap;
    reg [31:0] lba_log [0:511];
    integer    naddr = 0;

    always @(posedge clk) begin
        i_sd_data_valid <= 1'b0;
        i_sd_read_end   <= 1'b0;
        case (sst)
            M_IDLE: if (o_sd_read) begin
                caddr <= o_sd_addr;
                left  <= (o_sd_count <= 16'd1) ? 16'd1 : o_sd_count;
                bcnt  <= 16'd0;
                sst   <= M_LOCK;
                if (naddr < 512) begin
                    lba_log[naddr] = o_sd_addr;
                    naddr = naddr + 1;
                end
            end
            M_LOCK: begin
                i_sd_data       <= mem[memoff(caddr)*32'd512];
                i_sd_data_valid <= 1'b1;
                bcnt            <= 16'd1;
                gap             <= 8'd31;
                sst             <= M_DATA;
            end
            M_DATA: begin
                if (gap != 8'd0)
                    gap <= gap - 8'd1;
                else if (bcnt < 16'd512) begin
                    i_sd_data       <= mem[memoff(caddr)*32'd512 + bcnt];
                    i_sd_data_valid <= 1'b1;
                    bcnt            <= bcnt + 16'd1;
                    gap             <= 8'd31;
                end else
                    sst <= M_END;
            end
            M_END: begin
                i_sd_read_end <= 1'b1;
                if (left <= 16'd1) begin
                    gap <= 8'd6;          // 批结束：留出读核重采样的空隙
                    sst <= M_GAP;
                end else
                    sst <= M_NEXT;
            end
            M_NEXT: begin
                // CMD18 流式读：卡自己发下一个连续扇区
                caddr <= caddr + 32'd1;
                left  <= left - 16'd1;
                bcnt  <= 16'd0;
                sst   <= M_LOCK;
            end
            M_GAP: begin
                if (gap != 8'd0) gap <= gap - 8'd1;
                else             sst <= M_IDLE;
            end
            default: sst <= M_IDLE;
        endcase
    end

    // ---------------- 像素 / 音频收集 ----------------
    reg [15:0] got [0:94719];
    integer pcnt = 0;
    integer acnt = 0;
    reg [7:0] aud_bytes [0:15999];
    reg [7:0] exp_aud  [0:15999];

    // 期望音频字节：与前 2 帧相同，扇区号 k%12==11 属于音频区，
    // 每帧只取前 8000 字节（容器每帧 16×512=8192B，尾部 192B 补零被 reader 截掉）。
    // 帧 0：LBA 47361+k（run0 有 255 扇区）；
    // 帧 1：k<54 在 47562+k，k>=54 跳到 run1 513280+(k-54)。
    integer fa, fb, fp, fk;
    initial begin
        fb = 0;
        for (fa = 0; fa < 2; fa = fa + 1) begin
            fb = 0;
            for (fk = 0; fk < 201 && fb < 8000; fk = fk + 1) begin
                if ((fk % 12) == 11) begin
                    for (fp = 0; fp < 512 && fb < 8000; fp = fp + 1) begin
                        // mem[] 是文件内扇区偏移（见 memoff）：帧0 从偏移1开始，
                        // 帧1 前 54 扇区从偏移202开始，之后跳到 run1 的偏移256。
                        if (fa == 0)
                            exp_aud[fa*8000 + fb] = mem[(1 + fk) * 512 + fp];
                        else if (fk < 54)
                            exp_aud[fa*8000 + fb] = mem[(202 + fk) * 512 + fp];
                        else
                            exp_aud[fa*8000 + fb] = mem[(256 + fk - 54) * 512 + fp];
                        fb = fb + 1;
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (o_pix_en) begin
            if (pcnt < 94720) got[pcnt] <= o_pix;
            pcnt <= pcnt + 1;
        end
        if (o_aud_en) begin
            if (acnt < 16000) aud_bytes[acnt] <= o_aud_byte;
            acnt <= acnt + 1;
        end
    end

    // ---------------- 主流程 ----------------
    integer i, errs, first_bad;
    initial begin
        $readmemh("real_exp_pix.hex", exp_pix);
        rst = 1;
        repeat (10) @(posedge clk);
        rst = 0;

        // 2 帧 x 201 扇区 x 512B x 32 拍 = 6.59M 拍 = 65.9ms（100MHz）
        #75_000_000;

        $display("---- 地址序列（前 6 个）----");
        for (i = 0; i < 6 && i < naddr; i = i + 1)
            $display("  req[%0d] lba=%0d", i, lba_log[i]);
        $display("  最后一个 lba=%0d（期望 513280 附近的段 1 地址）", lba_log[naddr-1]);

        $display("---- 采集结果 ----");
        $display("  pix=%0d (期望 94720)  aud=%0d (期望 16000)  frame_no=%0d", pcnt, acnt, o_frame_no);

        errs = 0;
        first_bad = -1;
        for (i = 0; i < 94720; i = i + 1) begin
            if (got[i] !== exp_pix[i]) begin
                if (first_bad < 0) begin
                    first_bad = i;
                    $display("  首个错像素 i=%0d y=%0d x=%0d got=%04x exp=%04x",
                             i, i/320, i%320, got[i], exp_pix[i]);
                end
                errs = errs + 1;
            end
        end
        $display("  像素比对错误数 = %0d", errs);

        // ---- 音频字节内容比对（此前只数个数，内容一直没校验）----
        first_bad = -1;
        for (i = 0; i < 16000; i = i + 1) begin
            if (aud_bytes[i] !== exp_aud[i]) begin
                if (first_bad < 0) begin
                    first_bad = i;
                    $display("  首个错音频字节 i=%0d got=%02x exp=%02x",
                             i, aud_bytes[i], exp_aud[i]);
                end
                errs = errs + 1;
            end
        end
        $display("  含音频后的总错误数 = %0d", errs);
        if (errs == 0 && pcnt >= 94720 && acnt >= 16000)
            $display("TB_REAL_READER PASS");
        else
            $display("TB_REAL_READER FAIL errs=%0d pcnt=%0d acnt=%0d", errs, pcnt, acnt);
        $finish;
    end

endmodule
