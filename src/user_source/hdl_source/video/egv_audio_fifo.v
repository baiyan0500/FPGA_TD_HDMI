// ============================================================================
// egv_audio_fifo — 视频音轨跨时钟 FIFO（8192 x 16bit）
//
// 写域 sd_card_clk(100MHz)：egv_reader 按字节送入 s16le 交织样本，本模块
//   两字节拼成一个 16bit 样本（低字节先到）。
// 读域 audio_mclk(12.288MHz)：wav_i2s_source 以 FWFT 方式取样本（L/R 交替）。
//
// 深度取 8192 字 = 16384B ≈ 2 帧音频。原因：视频采用"整帧写入 SDRAM 再显示"
// 的双缓冲，音频必须比画面提前整整一帧准备好，峰值占用约 8000B（1 帧），
// 留一倍余量吸收 SD 读抖动。
//
// 存储：4 片 2048x16 双口 BRAM 拼接（与 sd_card_wav 同款已验证配置），
//       地址高 2 位选片，片内用低 11 位；读侧片选再打一拍对齐 BRAM 读延迟。
// 清空：i_flush / i_flush_r 保持高时两域指针恒为 0（停止播放期间一起归零）。
// ============================================================================
`timescale 1ns/1ps

module egv_audio_fifo (
    // ---- 写域 ----
    input  wire        i_wclk,
    input  wire        i_wrst,        // 同步复位
    input  wire        i_flush,       // 清空（保持高）
    input  wire        i_fstart,      // 帧起始：字节相位归零
    input  wire        i_wr_en,       // 字节写使能
    input  wire [7:0]  i_wr_byte,
    output reg  [13:0] o_count,       // 近似水位（字）

    // ---- 读域 ----
    input  wire        i_rclk,
    input  wire        i_rrst,
    input  wire        i_flush_r,
    input  wire        i_rd_en,
    output wire [15:0] o_rd_data,
    output wire        o_rd_empty
);

    localparam integer AW = 13;
    localparam [AW-1:0] DEPTH_1 = 13'd8191;

    // ------------------------------------------------------------------
    // 写域
    // ------------------------------------------------------------------
    reg        byte_ph;
    reg [7:0]  byte_lo;
    reg        wr_req;
    reg [15:0] wr_word;

    reg        full_q;
    reg        fifo_we2;
    reg [15:0] fifo_wd2;

    always @(posedge i_wclk or posedge i_wrst) begin
        if (i_wrst) begin
            byte_ph  <= 1'b0;
            byte_lo  <= 8'd0;
            wr_req   <= 1'b0;
            wr_word  <= 16'd0;
        end else if (i_flush) begin
            byte_ph  <= 1'b0;
            wr_req   <= 1'b0;
        end else begin
            wr_req <= 1'b0;
            if (i_fstart)
                byte_ph <= 1'b0;
            if (i_wr_en) begin
                if (!byte_ph) begin
                    byte_lo <= i_wr_byte;
                    byte_ph <= 1'b1;
                end else begin
                    wr_word <= {i_wr_byte, byte_lo};   // s16le
                    wr_req  <= 1'b1;
                    byte_ph <= 1'b0;
                end
            end
        end
    end

    reg  [AW-1:0] wbin;
    wire [AW-1:0] wgray = wbin ^ (wbin >> 1);
    reg  [AW-1:0] rbin;
    wire [AW-1:0] rgray = rbin ^ (rbin >> 1);
    reg  [AW-1:0] rgray_w1, rgray_w2;

    function [AW-1:0] gray2bin;
        input [AW-1:0] g;
        integer k;
        begin
            gray2bin[AW-1] = g[AW-1];
            for (k = AW-2; k >= 0; k = k - 1)
                gray2bin[k] = gray2bin[k+1] ^ g[k];
        end
    endfunction
    wire [AW-1:0] rbin_w = gray2bin(rgray_w2);

    always @(posedge i_wclk or posedge i_wrst) begin
        if (i_wrst) begin
            rgray_w1 <= {AW{1'b0}};
            rgray_w2 <= {AW{1'b0}};
            wbin     <= {AW{1'b0}};
        end else if (i_flush) begin
            wbin <= {AW{1'b0}};
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
            if (fifo_we2)
                wbin <= wbin + 1'b1;
        end
    end

    // 水位：gray2bin + 减法只到寄存器
    always @(posedge i_wclk or posedge i_wrst) begin
        if (i_wrst)
            o_count <= 14'd0;
        else if (i_flush)
            o_count <= 14'd0;
        else
            o_count <= {1'b0, wbin} - {1'b0, rbin_w};
    end

    wire [AW-1:0] wbin_next  = wbin + 1'b1;
    wire [AW-1:0] wgray_next = wbin_next ^ (wbin_next >> 1);
    wire          fifo_full  = (wgray_next == {~rgray_w2[AW-1:AW-2], rgray_w2[AW-3:0]});

    always @(posedge i_wclk or posedge i_wrst) begin
        if (i_wrst) begin
            full_q   <= 1'b0;
            fifo_we2 <= 1'b0;
            fifo_wd2 <= 16'd0;
        end else if (i_flush) begin
            full_q   <= 1'b0;
            fifo_we2 <= 1'b0;
        end else begin
            full_q   <= fifo_full;
            fifo_we2 <= wr_req && !full_q && (o_count != DEPTH_1);
            fifo_wd2 <= wr_word;
        end
    end

    // ------------------------------------------------------------------
    // 读域：两槽输出队列 + 3 拍取数（BRAM NOREG 同步读，1 拍出数）
    // ------------------------------------------------------------------
    wire [15:0]   lb0_dob, lb1_dob, lb2_dob, lb3_dob;
    reg  [AW-1:0] wgray_r1, wgray_r2;
    reg  [15:0]   q0_d, q1_d;
    reg  [1:0]    q_v;
    reg  [1:0]    fch;
    reg  [AW-1:0] rblk_d;
    wire          rd_empty_i = (rgray == wgray_r2);

    wire push        = (fch == 2'd2);
    wire pop         = i_rd_en && (q_v != 2'd0);
    wire fetch_start = (fch == 2'd0) && !rd_empty_i &&
                       (pop || (q_v < 2'd2));

    assign o_rd_empty = (q_v == 2'd0);
    assign o_rd_data  = q0_d;

    reg [15:0] dob_mux;
    always @(*) begin
        case (rblk_d)
            2'd0:    dob_mux = lb0_dob;
            2'd1:    dob_mux = lb1_dob;
            2'd2:    dob_mux = lb2_dob;
            default: dob_mux = lb3_dob;
        endcase
    end

    always @(posedge i_rclk) begin
        if (i_rrst || i_flush_r) begin
            wgray_r1 <= {AW{1'b0}};
            wgray_r2 <= {AW{1'b0}};
            rbin     <= {AW{1'b0}};
            q0_d     <= 16'd0;
            q1_d     <= 16'd0;
            q_v      <= 2'd0;
            fch      <= 2'd0;
            rblk_d   <= 2'd0;
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
            rblk_d   <= rbin[AW-1:AW-2];

            case (fch)
                2'd0: if (fetch_start) fch <= 2'd1;
                2'd1: fch <= 2'd2;
                2'd2: begin
                    fch  <= 2'd0;
                    rbin <= rbin + 1'b1;
                end
                default: fch <= 2'd0;
            endcase

            case ({push, pop})
                2'b10: begin
                    if (q_v == 2'd0) begin
                        q0_d <= dob_mux;
                        q_v  <= 2'd1;
                    end else begin
                        q1_d <= dob_mux;
                        q_v  <= 2'd2;
                    end
                end
                2'b01: begin
                    if (q_v == 2'd2) begin
                        q0_d <= q1_d;
                        q_v  <= 2'd1;
                    end else
                        q_v <= 2'd0;
                end
                2'b11: begin
                    if (q_v == 2'd2) begin
                        q0_d <= q1_d;
                        q1_d <= dob_mux;
                        q_v  <= 2'd2;
                    end else begin
                        q0_d <= dob_mux;
                        q_v  <= 2'd1;
                    end
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 存储体：4 x 2048x16，高 2 位选片
    // ------------------------------------------------------------------
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(11), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(11),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_blk0 (
        .dia(fifo_wd2), .addra(wbin[10:0]), .cea(1'b1), .ocea(1'b1),
        .clka(i_wclk), .wea(fifo_we2 && (wbin[AW-1:AW-2] == 2'd0)),
        .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(rbin[10:0]), .ceb(1'b1), .oceb(1'b1),
        .clkb(i_rclk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb0_dob)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(11), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(11),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_blk1 (
        .dia(fifo_wd2), .addra(wbin[10:0]), .cea(1'b1), .ocea(1'b1),
        .clka(i_wclk), .wea(fifo_we2 && (wbin[AW-1:AW-2] == 2'd1)),
        .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(rbin[10:0]), .ceb(1'b1), .oceb(1'b1),
        .clkb(i_rclk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb1_dob)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(11), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(11),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_blk2 (
        .dia(fifo_wd2), .addra(wbin[10:0]), .cea(1'b1), .ocea(1'b1),
        .clka(i_wclk), .wea(fifo_we2 && (wbin[AW-1:AW-2] == 2'd2)),
        .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(rbin[10:0]), .ceb(1'b1), .oceb(1'b1),
        .clkb(i_rclk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb2_dob)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(11), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(11),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_blk3 (
        .dia(fifo_wd2), .addra(wbin[10:0]), .cea(1'b1), .ocea(1'b1),
        .clka(i_wclk), .wea(fifo_we2 && (wbin[AW-1:AW-2] == 2'd3)),
        .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(rbin[10:0]), .ceb(1'b1), .oceb(1'b1),
        .clkb(i_rclk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb3_dob)
    );

endmodule
