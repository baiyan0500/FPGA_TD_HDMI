`timescale 1ns/1ps
// ============================================================================
// WAV 播放链路仿真：sd_card_wav + wav_i2s_source
//   · 模拟 SD 扇区读时序（read_end 后下一拍才允许锁新地址，与真实控制器一致）
//   · 斜坡 PCM 数据：每个 16bit 样本 +1（立体声 L 递增 / R 递减）
//   · 检查：扇区地址不重复不跳号、FIFO 不溢出、ASRC 消耗速率正确、
//           输出斜率 ≈ 1LSB/帧（丢字会变 2，重字会变 0.5/0）
// 运行：
//   vsim -c -gSTEREO=0 work.tb_wav_path -do "run -all; quit"
//   vsim -c -gSTEREO=1 work.tb_wav_path -do "run -all; quit"
// ============================================================================
module tb_wav_path;

parameter integer STEREO = 0;
parameter integer BPS    = 16;            // 16/24/32（样本位深）
parameter integer EXT    = 0;             // 1 = WAVE_FORMAT_EXTENSIBLE（子格式 PCM）
parameter integer RUN_FRAMES = 2700;

localparam [31:0] SECTOR_BASE = 32'd1000;
localparam integer BYTES_PER_SAMPLE = BPS / 8;
localparam integer CHANNELS = STEREO ? 2 : 1;
localparam integer DATA_SIZE   = 32760;          // 2/3/4 字节样本都能整除
localparam integer WORDS_TOTAL = DATA_SIZE / BYTES_PER_SAMPLE;  // FIFO 字数
localparam integer FRAMES_TOTAL = WORDS_TOTAL / CHANNELS;

reg clk = 0;
reg mclk = 0;
reg rst = 1;
always #5 clk = ~clk;                 // 100MHz
always #40.6665 mclk = ~mclk;         // 12.295082MHz

reg scan_done = 0;
reg wav_found = 0;
reg [31:0] wav_start = SECTOR_BASE;
reg pause = 0;

wire        wav_bus_req;
wire        bus_grant = wav_bus_req;

wire        sd_sec_read;
wire [31:0] sd_sec_addr;
reg  [7:0]  sd_sec_data = 8'd0;
reg         sd_sec_data_valid = 1'b0;
reg         sd_sec_read_end = 1'b0;

wire        fifo_rd_en;
wire [15:0] fifo_rd_data;
wire        fifo_empty;

wire        wav_active;
wire [32:0] wav_step;
wire        wav_stereo;
wire        o_valid;
wire signed [23:0] o_l;
wire signed [23:0] o_r;

sd_card_wav dut_wav (
    .clk                (clk),
    .rst                (rst),
    .i_scan_done        (scan_done),
    .i_wav_found        (wav_found),
    .i_wav_start_sector (wav_start),
    .i_pause            (pause),
    .o_bus_req          (wav_bus_req),
    .i_bus_grant        (bus_grant),
    .sd_sec_read        (sd_sec_read),
    .sd_sec_addr        (sd_sec_addr),
    .sd_sec_data        (sd_sec_data),
    .sd_sec_data_valid  (sd_sec_data_valid),
    .sd_sec_read_end    (sd_sec_read_end),
    .fifo_rd_clk        (mclk),
    .fifo_rd_en         (fifo_rd_en),
    .fifo_rd_data       (fifo_rd_data),
    .fifo_empty         (fifo_empty),
    .o_active           (wav_active),
    .o_rate_step        (wav_step),
    .o_stereo           (wav_stereo)
);

wav_i2s_source dut_src (
    .I_mclk             (mclk),
    .I_rst              (rst),
    .fifo_rd_en         (fifo_rd_en),
    .fifo_rd_data       (fifo_rd_data),
    .fifo_empty         (fifo_empty),
    .i_active           (wav_active),
    .i_pause            (pause),
    .i_step             (wav_step),
    .i_stereo           (wav_stereo),
    .o_valid            (o_valid),
    .o_l                (o_l),
    .o_r                (o_r)
);

// ---------------------------------------------------------------------------
// WAV 头：+HDR=0 经典 44 字节；+HDR=1 真实卡布局（fmt16 @12，LIST26 @36，
// data @70 → payload @78，chunk 起点非 4 字节对齐）；+HDR=2 含奇数长度 chunk
// （junk size=5 + 1 字节填充）。
// EXT=1 时 fmt 用 WAVE_FORMAT_EXTENSIBLE（cbSize=22 + 有效位 + 掩码 + PCM GUID）
// ---------------------------------------------------------------------------
reg [7:0] hdr [0:1023];
integer   hdr_len  = 44;
integer   hdr_mode = 0;

task w8(input integer off, input [7:0] v);
    begin hdr[off] = v; end
endtask

task w16(input integer off, input [15:0] v);
    begin hdr[off] = v[7:0]; hdr[off+1] = v[15:8]; end
endtask

task w32(input integer off, input [31:0] v);
    begin
        hdr[off]   = v[7:0];  hdr[off+1] = v[15:8];
        hdr[off+2] = v[23:16];hdr[off+3] = v[31:24];
    end
endtask

task wtag(input integer off, input [31:0] v);
    begin hdr[off] = v[31:24]; hdr[off+1] = v[23:16]; hdr[off+2] = v[15:8]; hdr[off+3] = v[7:0]; end
endtask

task build_hdr;
    integer p, k;
    reg [15:0] ch;
    reg [31:0] br;
    reg [15:0] fmt_size;
    begin
        for (k = 0; k < 1024; k = k + 1) hdr[k] = 8'h00;
        ch = STEREO ? 16'd2 : 16'd1;
        br = 48000 * CHANNELS * BYTES_PER_SAMPLE;
        wtag(0, "RIFF"); wtag(8, "WAVE");
        p = 12;
        if (hdr_mode == 2) begin           // 奇数长度 chunk + 填充字节
            wtag(p, "junk"); w32(p+4, 32'd5);
            w8(p+8, 8'hA5); w8(p+9, 8'h5A); w8(p+10, 8'h11);
            w8(p+11, 8'h22); w8(p+12, 8'h33);
            p = p + 8 + 5 + 1;
        end
        fmt_size = EXT ? 16'd40 : 16'd16;
        wtag(p, "fmt "); w32(p+4, {16'd0, fmt_size});
        w16(p+8,  EXT ? 16'hFFFE : 16'd1);   // PCM / EXTENSIBLE
        w16(p+10, ch); w32(p+12, 32'd48000);
        w32(p+16, br); w16(p+20, ch*BYTES_PER_SAMPLE); w16(p+22, BPS);
        if (EXT) begin
            w16(p+24, 16'd22);               // cbSize
            w16(p+26, BPS);                  // wValidBitsPerSample
            w32(p+28, STEREO ? 32'h3 : 32'h4);// dwChannelMask
            // SubFormat GUID = KSDATAFORMAT_SUBTYPE_PCM
            w8(p+32,8'h01); w8(p+33,8'h00); w8(p+34,8'h00); w8(p+35,8'h00);
            w8(p+36,8'h00); w8(p+37,8'h00); w8(p+38,8'h10); w8(p+39,8'h00);
            w8(p+40,8'h80); w8(p+41,8'h00); w8(p+42,8'h00); w8(p+43,8'hAA);
            w8(p+44,8'h00); w8(p+45,8'h38); w8(p+46,8'h9B); w8(p+47,8'h71);
        end
        p = p + 8 + fmt_size;
        if (hdr_mode >= 1) begin          // LIST/INFO：实际卡上 size=26 的元数据块
            wtag(p, "LIST"); w32(p+4, 32'd26);
            wtag(p+8, "INFO");
            for (k = 0; k < 22; k = k + 1) w8(p + 12 + k, 8'h20 + k[7:0]);
            p = p + 8 + 26;
        end
        wtag(p, "data"); w32(p+4, DATA_SIZE);
        p = p + 8;
        hdr_len = p;
        w32(4, hdr_len + DATA_SIZE - 8);   // RIFF size 回填
    end
endtask

// 数据区：每个样本的末两字节装斜坡（其余字节为 0），保证 FIFO 取高 16bit
// 后与 16bit 版本逐字相同，从而复用同一套期望序列。
function [7:0] sec_byte;
    input [31:0] sec;
    input integer i;
    integer foff, g, j, lane, fr, v;
    begin
        foff = (sec - SECTOR_BASE) * 512 + i;
        if (foff < hdr_len) begin
            sec_byte = hdr[foff];
        end else begin
            g    = foff - hdr_len;
            j    = g / BYTES_PER_SAMPLE;      // 样本序号
            lane = g % BYTES_PER_SAMPLE;
            if (STEREO) begin
                fr = (j / 2) % FRAMES_TOTAL;
                v  = j[0] ? (30000 - fr) : fr;
            end else begin
                fr = j % FRAMES_TOTAL;
                v  = fr;
            end
            if (lane == BYTES_PER_SAMPLE - 1)
                sec_byte = (v >> 8) & 8'hFF;
            else if (lane == BYTES_PER_SAMPLE - 2)
                sec_byte = v & 8'hFF;
            else
                sec_byte = 8'h00;
        end
    end
endfunction

// ---------------------------------------------------------------------------
// SD 扇区响应器（模拟 sd_card_top 行为：整扇区 512 字节 + read_end 单拍）
// ---------------------------------------------------------------------------
// 真实控制器在 S_READ_END 之后一拍才进 S_WAIT_READ_WRITE，并在那里
// 再下一拍锁存 sd_sec_addr；SD_WAIT 精确复现这个"晚两拍"的采样时刻。
localparam SD_IDLE = 3'd0, SD_PRE = 3'd1, SD_DATA = 3'd2, SD_DONE = 3'd3, SD_WAIT = 3'd4;

reg [2:0]  sd_st = SD_IDLE;
reg [31:0] xfer_addr = 32'd0;
reg [9:0]  xfer_idx = 10'd0;
reg [7:0]  gap = 8'd0;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        sd_st <= SD_IDLE;
        sd_sec_data <= 8'd0;
        sd_sec_data_valid <= 1'b0;
        sd_sec_read_end <= 1'b0;
        xfer_addr <= 32'd0;
        xfer_idx <= 10'd0;
        gap <= 8'd0;
    end else begin
        sd_sec_data_valid <= 1'b0;
        sd_sec_read_end <= 1'b0;
        case (sd_st)
            SD_IDLE: if (sd_sec_read && bus_grant)
                sd_st <= SD_WAIT;
            SD_WAIT: if (sd_sec_read && bus_grant) begin
                xfer_addr <= sd_sec_addr;    // 与 sd_card_sec_read_write 同拍锁存
                xfer_idx  <= 10'd0;
                gap       <= 8'd40;
                sd_st     <= SD_PRE;
            end
            SD_PRE: begin
                if (gap != 8'd0)
                    gap <= gap - 8'd1;
                else begin
                    sd_sec_data       <= sec_byte(xfer_addr, 0);
                    sd_sec_data_valid <= 1'b1;
                    xfer_idx          <= 10'd1;
                    sd_st             <= SD_DATA;
                end
            end
            SD_DATA: begin
                if (xfer_idx == 10'd512) begin
                    sd_sec_read_end <= 1'b1;
                    sd_st           <= SD_DONE;
                end else begin
                    sd_sec_data       <= sec_byte(xfer_addr, xfer_idx);
                    sd_sec_data_valid <= 1'b1;
                    xfer_idx          <= xfer_idx + 10'd1;
                end
            end
            SD_DONE: sd_st <= SD_WAIT;
            default: sd_st <= SD_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// 检查：扇区顺序 / FIFO 水位 / FIFO 字序 / 输出斜率
// ---------------------------------------------------------------------------
integer fcnt = 0;
integer rd_cnt = 0;
integer werr_cnt = 0;
integer serr_cnt = 0;
integer ferr_cnt = 0;
integer word_idx = 0;
integer max_occ = 0;
integer last_sector = -1;

integer win_yl = 0;
integer win_yr = 0;
integer win_rd = 0;                  // 窗口起点的 pop 计数（判断是否跨数据回绕）
localparam integer POP_PERIOD = STEREO ? (2*FRAMES_TOTAL) : FRAMES_TOTAL;
wire [15:0] yl = o_l[23:8];
wire [15:0] yr = o_r[23:8];

function [15:0] expected_word;
    input integer k;
    integer s;
    begin
        if (STEREO) begin
            s = (k / 2) % FRAMES_TOTAL;
            expected_word = k[0] ? (30000 - s) : s;
        end else begin
            expected_word = k % FRAMES_TOTAL;
        end
    end
endfunction

// FIFO 弹出的每个字必须与斜坡序列逐一对应（丢字/重字/错序会立即报错）
always @(posedge mclk) begin
    if (!rst && fifo_rd_en) begin
        if (fifo_rd_data !== expected_word(word_idx)) begin
            werr_cnt = werr_cnt + 1;
            if (werr_cnt <= 10)
                $display("ERR word idx=%0d got=%0d exp=%0d",
                         word_idx, fifo_rd_data, expected_word(word_idx));
        end
        // 数据区循环播放：下标也按 WORDS_TOTAL 回绕
        word_idx = (word_idx + 1) % WORDS_TOTAL;
    end
end

always @(posedge clk) begin
    if (!rst && sd_sec_read_end && (dut_wav.state == 3'd3)) begin
        if (last_sector >= 0) begin
            if (!((xfer_addr == last_sector + 1) || (xfer_addr == SECTOR_BASE))) begin
                serr_cnt = serr_cnt + 1;
                $display("ERR sector seq: %0d -> %0d", last_sector, xfer_addr);
            end
        end
        last_sector = xfer_addr;
    end
end

always @(posedge mclk) begin
    if (!rst) begin
        if (fifo_rd_en)
            rd_cnt = rd_cnt + 1;

        if ((dut_src.as == 3'd3) && (dut_src.fphase == 8'd255)) begin
            fcnt = fcnt + 1;

            if (fcnt == 200) begin
                win_yl = yl;
                win_yr = yr;
                win_rd = rd_cnt;
            end else if ((fcnt > 200) && (((fcnt - 200) % 500) == 0)) begin
                // 数据区循环点处斜坡本身会跳变，跨回绕的窗口不做斜率判定
                if ((win_rd / POP_PERIOD) == (rd_cnt / POP_PERIOD)) begin
                    if ((yl - win_yl < 490) || (yl - win_yl > 510)) begin
                        ferr_cnt = ferr_cnt + 1;
                        $display("ERR L slope @%0d: d=%0d", fcnt, yl - win_yl);
                    end
                    if (STEREO) begin
                        if ((yr - win_yr > -490) || (yr - win_yr < -510)) begin
                            ferr_cnt = ferr_cnt + 1;
                            $display("ERR R slope @%0d: d=%0d", fcnt, yr - win_yr);
                        end
                    end
                end
                if (!STEREO && (o_l !== o_r)) begin
                    ferr_cnt = ferr_cnt + 1;
                    $display("ERR mono L!=R @%0d: l=%0d r=%0d", fcnt, yl, yr);
                end
                win_yl = yl;
                win_yr = yr;
                win_rd = rd_cnt;
            end

            if (fcnt >= RUN_FRAMES) begin
                if (max_occ >= 2000) begin
                    ferr_cnt = ferr_cnt + 1;
                    $display("ERR fifo near full: max=%0d", max_occ);
                end
                if (STEREO) begin
                    if ((rd_cnt < 2*fcnt - 20) || (rd_cnt > 2*fcnt + 20)) begin
                        ferr_cnt = ferr_cnt + 1;
                        $display("ERR pop rate: rd=%0d frames=%0d", rd_cnt, fcnt);
                    end
                end else begin
                    if ((rd_cnt < fcnt - 20) || (rd_cnt > fcnt + 20)) begin
                        ferr_cnt = ferr_cnt + 1;
                        $display("ERR pop rate: rd=%0d frames=%0d", rd_cnt, fcnt);
                    end
                end
                if ((ferr_cnt + werr_cnt + serr_cnt) == 0)
                    $display("PASS stereo=%0d bps=%0d ext=%0d hdr=%0d frames=%0d pops=%0d max_fifo=%0d",
                             STEREO, BPS, EXT, hdr_mode, fcnt, rd_cnt, max_occ);
                else
                    $display("FAIL stereo=%0d bps=%0d ext=%0d hdr=%0d slope=%0d word=%0d sector=%0d frames=%0d",
                             STEREO, BPS, EXT, hdr_mode, ferr_cnt, werr_cnt, serr_cnt, fcnt);
                $finish;
            end
        end
    end
end

always @(posedge clk) begin
    if (!rst && (dut_wav.wcount_q > max_occ))
        max_occ = dut_wav.wcount_q;
end

initial begin
    if ($value$plusargs("HDR=%d", hdr_mode)) ;
    build_hdr;
    $display("hdr_mode=%0d hdr_len=%0d data_size=%0d bps=%0d ext=%0d stereo=%0d",
             hdr_mode, hdr_len, DATA_SIZE, BPS, EXT, STEREO);
    rst = 1;
    #200;
    rst = 0;
    #100;
    scan_done = 1;
    wav_found = 1;
end

initial begin
    #(RUN_FRAMES * 42_000 + 5_000_000);   // 每帧 20.8us，留一倍余量
    $display("TIMEOUT: frames=%0d wav_state=%0d sd_state=%0d fifo_cnt=%0d active=%0d",
             fcnt, dut_wav.state, sd_st, dut_wav.wcount_q, wav_active);
    $finish;
end

endmodule
