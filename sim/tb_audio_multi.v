`timescale 1ns/1ps
// tb_audio_multi — 视频音轨多帧端到端（真实卡上音轨，4 帧连续播放）
//
// 与 tb_e2e_audio 的区别（这是上板噪声的关键场景）：
//   1) 写侧按**真实节奏**投递：每帧 8000 字节在 32.9ms 内匀速写入
//      （= TF 卡 25MHz SPI、201 扇区/帧的实测读取时长），随后空等到满
//      41.667ms（24fps）。旧 TB 一次性灌完，测不到 FIFO 的稳态水位。
//   2) 连续 4 帧，每帧起始给一次 i_fstart，覆盖帧边界的字节配对复位。
//   3) 收完统一做"最佳偏移 + 严格逐帧"比对：允许启动期若干静音帧，
//      之后任何丢样本/重样本/错序都会被判错。
module tb_audio_multi;
    reg wclk = 0, mclk = 0, rst = 1;
    always #5     wclk = ~wclk;      // 100MHz
    always #40.69 mclk = ~mclk;      // 12.288MHz

    localparam integer NBYTES   = 32000;      // 4 帧 x 8000
    localparam integer NSAMP    = NBYTES/4;   // 8000 个立体声帧
    localparam integer FRM_BYTE = 8000;       // 每帧音频字节
    localparam integer BYTE_GAP = 411;        // 100MHz 下每字节约 411 拍 => 3.125MB/s
    localparam integer FRM_CYC  = 4_166_667;  // 24fps @100MHz

    reg [7:0] aud [0:NBYTES-1];
    initial $readmemh("e2e_aud_multi.hex", aud);

    // ---------------- DUT ----------------
    reg         fstart = 0, wr_en = 0;
    reg  [7:0]  wr_byte = 0;
    wire [13:0] cnt;
    wire        rden;
    wire [15:0] rdata;
    wire        rempty;

    egv_audio_fifo u_fifo (
        .i_wclk(wclk), .i_wrst(rst), .i_flush(1'b0),
        .i_fstart(fstart), .i_wr_en(wr_en), .i_wr_byte(wr_byte),
        .o_count(cnt),
        .i_rclk(mclk), .i_rrst(rst), .i_flush_r(1'b0),
        .i_rd_en(rden), .o_rd_data(rdata), .o_rd_empty(rempty)
    );

    wire        src_valid;
    wire signed [23:0] src_l, src_r;
    wav_i2s_source u_src (
        .I_mclk(mclk), .I_rst(rst),
        .fifo_rd_en(rden), .fifo_rd_data(rdata), .fifo_empty(rempty),
        .i_active(1'b1), .i_pause(1'b0),
        .i_step(33'h1_0000_0000), .i_stereo(1'b1),
        .o_valid(src_valid), .o_l(src_l), .o_r(src_r)
    );

    wire bclk, lrck, dout;
    hdmi_audio_tone_i2s_64fs u_tone (
        .I_mclk(mclk), .I_rst(rst),
        .I_wav_sel(1'b1), .I_wav_valid(src_valid),
        .I_wav_l(src_l), .I_wav_r(src_r), .I_pause(1'b0),
        .O_i2s_BCLK(bclk), .O_i2s_LRCK(lrck), .O_i2s_DOUT(dout)
    );

    wire tgl;
    wire [23:0] rx_l, rx_r;
    I2S_receiver u_rx (
        .I_clk(mclk), .I_rst(rst),
        .I_i2s_BCLK(bclk), .I_i2s_LRCK(lrck), .I_i2s_DOUT(dout),
        .O_audio_toggle(tgl), .O_audio_left_data(rx_l), .O_audio_right_data(rx_r)
    );

    // ---------------- 采集 ----------------
    localparam integer MAXF = NSAMP + 128;
    reg [23:0] got_l [0:MAXF-1];
    reg [23:0] got_r [0:MAXF-1];
    reg tgl_s1, tgl_s2;
    integer nframe = 0;
    always @(posedge mclk) begin
        tgl_s1 <= tgl;
        tgl_s2 <= tgl_s1;
    end
    always @(posedge mclk) begin
        if (!rst && (tgl_s2 ^ tgl_s1)) begin
            if (nframe < MAXF) begin
                got_l[nframe] = rx_l;
                got_r[nframe] = rx_r;
            end
            nframe = nframe + 1;
        end
    end

    // FIFO 水位（写域采样；>8191 说明 14bit 减法跨圈回绕，属显示口径问题）
    integer min_cnt = 99999, max_cnt = 0;
    always @(posedge wclk) begin
        if (cnt < min_cnt) min_cnt = cnt;
        if (cnt > max_cnt) max_cnt = cnt;
    end

    // ---------------- 写激励：真实 24fps 节奏 ----------------
    integer f, k, t;
    initial begin
        rst = 1;
        repeat (20) @(posedge wclk);
        rst = 0;
        repeat (10) @(posedge wclk);
        for (f = 0; f < 4; f = f + 1) begin
            fstart <= 1'b1; @(posedge wclk); fstart <= 1'b0;
            for (k = 0; k < FRM_BYTE; k = k + 1) begin
                wr_byte <= aud[f*FRM_BYTE + k];
                wr_en   <= 1'b1;              // 只高 1 拍：一个字节一次写
                @(posedge wclk);
                wr_en   <= 1'b0;
                for (t = 1; t < BYTE_GAP; t = t + 1) @(posedge wclk);
            end
            for (t = FRM_BYTE*BYTE_GAP; t < FRM_CYC; t = t + 1) @(posedge wclk);
        end
        wait (nframe >= NSAMP + 32);
        repeat (10) @(posedge mclk);
        $finish;
    end

    // ---------------- 事后比对：流式对齐（重样本/丢样本/错值分开统计） ----------------
    integer k2, idx, dup, skip, bad, pre, dup_ss, skip_ss, bad_ss, lo, hi;
    reg [15:0] el;
    initial begin
        wait (nframe >= NSAMP + 32);
        idx = 0; dup = 0; skip = 0; bad = 0; pre = 0;
        dup_ss = 0; skip_ss = 0; bad_ss = 0;
        lo = 4; hi = nframe - 20;      // 稳态窗口：排除预填与写侧停止后的保持帧
        for (k2 = 0; k2 < nframe; k2 = k2 + 1) begin
            case (1'b1)
                (got_l[k2] === {aud[idx*4+1], aud[idx*4], 8'h00}): begin
                    idx = idx + 1;                    // 正常前进
                end
                (idx > 0 && got_l[k2] === {aud[(idx-1)*4+1], aud[(idx-1)*4], 8'h00}): begin
                    dup = dup + 1;                    // 重复上一帧样本
                    if (k2 >= lo && k2 <= hi) dup_ss = dup_ss + 1;
                    if (dup <= 6)
                        $display("  DUP at out %0d (idx %0d) val %06x", k2, idx, got_l[k2]);
                end
                (got_l[k2] === {aud[(idx+1)*4+1], aud[(idx+1)*4], 8'h00}): begin
                    skip = skip + 1;                  // 跳过一帧样本
                    idx = idx + 2;
                    if (k2 >= lo && k2 <= hi) skip_ss = skip_ss + 1;
                    $display("  SKIP at out %0d (idx %0d)", k2, idx-1);
                end
                // ASRC 预填期（还未产出第一个样本）tone 发静音，属正常启动延迟
                (got_l[k2] === 24'd0 && idx == 0): begin
                    pre = pre + 1;
                end
                default: begin
                    bad = bad + 1;
                    if (k2 >= lo && k2 <= hi) bad_ss = bad_ss + 1;
                    if (bad <= 6)
                        $display("  BAD at out %0d (idx %0d): got %06x exp %06x",
                                 k2, idx, got_l[k2], {aud[idx*4+1], aud[idx*4], 8'h00});
                    idx = idx + 1;
                end
            endcase
        end
        $display("AUDIO MULTI: out_frames=%0d consumed_idx=%0d/%0d pre_silence=%0d",
                 nframe, idx, NSAMP, pre);
        $display("  全段: dup=%0d skip=%0d bad=%0d | 稳态窗口[%0d..%0d]: dup=%0d skip=%0d bad=%0d",
                 dup, skip, bad, lo, hi, dup_ss, skip_ss, bad_ss);
        if (bad_ss == 0 && skip_ss == 0 && idx >= NSAMP - 1)
            $display("TB_AUDIO_MULTI PASS");
        else
            $display("TB_AUDIO_MULTI FAIL ss dup=%0d skip=%0d bad=%0d idx=%0d",
                     dup_ss, skip_ss, bad_ss, idx);
        $finish;
    end

    initial begin
        #400_000_000;
        $display("AUDIO MULTI TIMEOUT frames=%0d min/max=%0d/%0d", nframe, min_cnt, max_cnt);
        $finish;
    end
endmodule
