module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [4:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [4:0]            scan_found_total,
    output reg                  wav_found,          // 扫描发现 WAV 文件
    output reg [31:0]           wav_start_sector,   // WAV 起始扇区

    // 按指定扇区加载一张图到 SDRAM
    input                       load_start,
    input                       load_abort,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output [15:0]               src_width,     // 实际图片宽（缩放源）
    output [15:0]               src_height,    // 实际图片高
    input                       i_stall,       // 背压：暂停读取（scaler FIFO 快满时）

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;

reg [2:0]  state;
reg [9:0]  rd_cnt;

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [31:0] file_len;
reg [31:0] pixel_offset;
reg [31:0] width;
reg [31:0] height;
reg [15:0] bit_count;
reg [31:0] compression;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [31:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [12:0] row_bytes;          // 当前行内偏移（含行尾 4 字节对齐填充）
reg [10:0] pix_row;            // 已完成的像素行数

// 扫描步进：未命中的扇区一次跳过 8 个（4KB）。文件起始扇区一定落在簇边界上，
// exFAT/大簇 FAT32 的簇 ≥ 4KB，因此不会漏文件；逐扇区扫描时 1.7 万个空扇区
// （本卡 03_3 到 WAV 之间）要花 2.8s，改为 4KB 步进后约 0.35s。
// 每次未命中都对齐到 8 的整数倍，避免文件跳转把扫描栅格带偏后漏掉后续文件。
// 注意：不能用"连续空档多少次就收工"的预算来限时——FAT32 的 FAT 表本身就在
// 数据区之前，32GB/4KB 簇的卡 FAT 约 32MB，空档远超任何小预算；一旦提前收工
// 就是"0 张图片，显示 NO IMAGE ON SD"。只能以 scan_max_sector 为界扫满。
localparam [31:0] SCAN_STEP      = 32'd8;

// RIFF/WAVE 头锁存（扫描期识别 WAV 文件）
reg [7:0]  riff_id0, riff_id1, riff_id2, riff_id3;
reg [7:0]  wave_id0, wave_id1, wave_id2, wave_id3;
reg [31:0] riff_size;

wire header_match;
wire wav_match;
wire bmp_data_valid;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;
wire [31:0] next_scan_sector_if_wav;

// 扇区跳转数预计算寄存：头字节锁存拍完成 32bit 加法/移位，扫描状态机
// 关键路径上只剩"scan_sector + 预计算值"一级加法（否则两级 32bit 运算
// 串联直驱 sd_sec_read_addr/scan_sector，100MHz 下 SWNS -3.661ns）
reg  [31:0] file_sector_count_q;   // BMP：rd_cnt==5 算粗值，==6 修正 0→1
reg  [31:0] wav_skip_sectors_q;    // WAV：rd_cnt==7 算粗值，==8 修正 0→1

assign ready = (state == ST_IDLE);
assign header_match = (header_0 == "B") &&
                      (header_1 == "M") &&
                      (bit_count    == 16'd24) &&
                      (compression  == 32'd0);
// 只接受自底向上、宽度 ≤1024（scaler 行缓存深度）、高度 ≤2047（11bit）
// 的 24bit 未压缩 BMP；负高度=自顶向下，当前像素流按自底向上处理，直接拒绝
wire [12:0] row_pix_bytes_w = {1'b0, width[10:0]} * 13'd3;
wire [12:0] row_stride_w    = (row_pix_bytes_w + 13'd3) & 13'h1FFC;
// 行宽/行跨距预先寄存：width 在头解析后恒定，若让乘法器+加法器直接驱动
// 行计数使能与数据有效，100MHz 下时序为 -0.083ns（MULT18 3.5ns + 进位链）
reg  [12:0] row_pix_bytes;
reg  [12:0] row_stride;
always @(posedge clk or posedge rst) begin
    if (rst) begin
        row_pix_bytes <= 13'd0;
        row_stride    <= 13'd0;
    end else begin
        row_pix_bytes <= row_pix_bytes_w;
        row_stride    <= row_stride_w;
    end
end
wire size_ok = (width  != 32'd0)    && (width  <= 32'd1024) &&
               (height != 32'd0)    && (height <= 32'd2047) &&
               (file_len > pixel_offset);
wire header_ok = header_match && size_ok;
// 判定结果打一拍：read_end 拍只剩寄存器输出，避免新增 32bit 比较器
// 直驱扫描地址/状态机（100MHz 关键路径）
reg  header_ok_r;
always @(posedge clk or posedge rst) begin
    if (rst)
        header_ok_r <= 1'b0;
    else
        header_ok_r <= header_ok;
end
assign wav_match = (riff_id0 == "R") && (riff_id1 == "I") &&
                   (riff_id2 == "F") && (riff_id3 == "F") &&
                   (wave_id0 == "W") && (wave_id1 == "A") &&
                   (wave_id2 == "V") && (wave_id3 == "E");
assign src_width  = width[15:0];
assign src_height = height[15:0];
assign bmp_data_valid = (sd_sec_read_data_valid == 1'b1) &&
                        (bmp_len_cnt >= pixel_offset) &&
                        (bmp_len_cnt <  file_len) &&
                        (row_bytes < row_pix_bytes) &&
                        (pix_row < height[10:0]);
assign next_scan_sector_if_match = scan_sector + file_sector_count_q;
assign next_scan_sector_if_miss  = (scan_sector + SCAN_STEP) & 32'hFFFF_FFF8;
// RIFF size = 文件长度 - 8，占 (riff_size + 8 + 511) >> 9 个扇区
assign next_scan_sector_if_wav   = scan_sector + wav_skip_sectors_q;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_data_valid)
            rd_cnt <= rd_cnt + 10'd1;
        else if (sd_sec_read_end)
            rd_cnt <= 10'd0;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 32'd0;
        pixel_offset <= 32'd54;
        width        <= 32'd0;
        height       <= 32'd0;
        bit_count    <= 16'd0;
        compression  <= 32'd0;
        riff_id0     <= 8'd0;
        riff_id1     <= 8'd0;
        riff_id2     <= 8'd0;
        riff_id3     <= 8'd0;
        wave_id0     <= 8'd0;
        wave_id1     <= 8'd0;
        wave_id2     <= 8'd0;
        wave_id3     <= 8'd0;
        riff_size    <= 32'd0;
        file_sector_count_q <= 32'd1;
        wav_skip_sectors_q  <= 32'd1;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        case (rd_cnt)
            10'd0 : begin
                header_0 <= sd_sec_read_data;
                riff_id0 <= sd_sec_read_data;
            end
            10'd1 : begin
                header_1 <= sd_sec_read_data;
                riff_id1 <= sd_sec_read_data;
            end

            10'd2 : begin
                file_len[7:0]   <= sd_sec_read_data;
                riff_id2        <= sd_sec_read_data;
            end
            10'd3 : begin
                file_len[15:8]  <= sd_sec_read_data;
                riff_id3        <= sd_sec_read_data;
            end

            10'd4 : begin
                file_len[23:16] <= sd_sec_read_data;
                riff_size[7:0]  <= sd_sec_read_data;
            end
            10'd5 : begin
                file_len[31:24] <= sd_sec_read_data;
                riff_size[15:8] <= sd_sec_read_data;
                // BMP 跳转扇区数：file_len 32bit 到齐，本拍算粗值（仅到寄存器 D）
                // 小端：字节 5 是 MSB，须放拼接最高位（{旧[23:0],新} 会把值错移 8 位）
                file_sector_count_q <= ({sd_sec_read_data, file_len[23:0]} + 32'd511) >> 9;
            end
            10'd6 : begin
                riff_size[23:16] <= sd_sec_read_data;
                file_sector_count_q <= (file_sector_count_q == 32'd0) ? 32'd1 : file_sector_count_q;
            end
            10'd7 : begin
                riff_size[31:24] <= sd_sec_read_data;
                // WAV 跳转扇区数：riff_size 32bit 到齐，本拍算粗值
                // 小端：字节 7 是 MSB，须放拼接最高位
                wav_skip_sectors_q <= ({sd_sec_read_data, riff_size[23:0]} + 32'd519) >> 9;
            end
            10'd8 : begin
                wave_id0 <= sd_sec_read_data;
                wav_skip_sectors_q <= (wav_skip_sectors_q == 32'd0) ? 32'd1 : wav_skip_sectors_q;
            end
            10'd9 : wave_id1 <= sd_sec_read_data;
            10'd10: begin
                wave_id2 <= sd_sec_read_data;
                pixel_offset[7:0] <= sd_sec_read_data;
            end
            10'd11: begin
                wave_id3 <= sd_sec_read_data;
                pixel_offset[15:8] <= sd_sec_read_data;
            end
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: pixel_offset[31:24] <= sd_sec_read_data;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: width[23:16] <= sd_sec_read_data;
            10'd21: width[31:24] <= sd_sec_read_data;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: height[23:16] <= sd_sec_read_data;
            10'd25: height[31:24] <= sd_sec_read_data;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: compression[7:0] <= sd_sec_read_data;
            10'd31: compression[15:8] <= sd_sec_read_data;
            10'd32: compression[23:16] <= sd_sec_read_data;
            10'd33: compression[31:24] <= sd_sec_read_data;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt <= 32'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (sd_sec_read_data_valid)
            bmp_len_cnt <= bmp_len_cnt + 32'd1;
    end else begin
        bmp_len_cnt <= 32'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        row_bytes <= 13'd0;
        pix_row   <= 11'd0;
    end else if (state == ST_LOAD_DATA) begin
        // 数据区每个字节都推进行内偏移（含填充字节），像素有效窗口由
        // bmp_data_valid 的 row_bytes < row_pix_bytes 限定
        if (sd_sec_read_data_valid && (bmp_len_cnt >= pixel_offset) &&
            (pix_row < height[10:0])) begin
            if (row_bytes + 13'd1 >= row_stride) begin
                row_bytes <= 13'd0;
                pix_row   <= pix_row + 11'd1;
            end else begin
                row_bytes <= row_bytes + 13'd1;
            end
        end
    end else begin
        row_bytes <= 13'd0;
        pix_row   <= 11'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_byte_idx <= 2'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid)
            bmp_byte_idx <= (bmp_byte_idx == 2'd2) ? 2'd0 : (bmp_byte_idx + 2'd1);
    end else begin
        bmp_byte_idx <= 2'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_data_wr_en <= 1'b0;
        bmp_data       <= 24'd0;
    end else if (state == ST_LOAD_DATA) begin
        if (bmp_data_valid) begin
            case (bmp_byte_idx)
                2'd0: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[7:0]  <= sd_sec_read_data;
                end
                2'd1: begin
                    bmp_data_wr_en <= 1'b0;
                    bmp_data[15:8] <= sd_sec_read_data;
                end
                2'd2: begin
                    bmp_data_wr_en  <= 1'b1;
                    bmp_data[23:16] <= sd_sec_read_data;
                end
                default: begin
                    bmp_data_wr_en <= 1'b0;
                end
            endcase
        end else begin
            bmp_data_wr_en <= 1'b0;
        end
    end else begin
        bmp_data_wr_en <= 1'b0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 5'd0;
        wav_found         <= 1'b0;
        wav_start_sector  <= 32'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (!sd_init_done) begin
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 5'd0;
        wav_found         <= 1'b0;
        wav_start_sector  <= 32'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
    end else if (load_abort) begin
        // 仅中止当前装载，保留扫描成果（scan_done 等），否则一次坏图超时就永久报废切图功能
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_found_valid  <= 1'b0;
        load_sector_latched <= 32'd0;
    end else begin
        scan_found_valid <= 1'b0;

        case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 5'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_ok_r) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 5'd1;

                        if (((scan_found_total + 5'd1 >= scan_target_count) && wav_found) ||
                            (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end
                        sd_sec_read_addr <= next_scan_sector_if_match;
                        scan_sector      <= next_scan_sector_if_match;
                    end else if (wav_match) begin
                        // WAV 文件：记录起始扇区，按 RIFF size 整体跳过
                        wav_found        <= 1'b1;
                        wav_start_sector <= scan_sector;

                        if (scan_found_total >= scan_target_count) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end
                        sd_sec_read_addr <= next_scan_sector_if_wav;
                        scan_sector      <= next_scan_sector_if_wav;
                    end else begin
                        // 未命中：4KB 对齐步进，扫到 scan_max_sector 为止
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_ok_r) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        state <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                // 背压只在扇区边界生效：SD 核只在固定窗口采样 sd_sec_read，
                // 中途撤销会让请求被丢弃（end 永不到来），仲裁器 bmp_rd_busy
                // 因此卡在 1，WAV 永远拿不到总线 → 播几张后整机死锁。
                // 停一拍后必须"保持低"直到 i_stall 解除，否则背压形同虚设，
                // scaler 输入 FIFO 会在一个扇区内溢出丢像素。
                if (sd_sec_read_end)
                    sd_sec_read <= ~i_stall;
                else if (!sd_sec_read)
                    sd_sec_read <= ~i_stall;
                else
                    sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    // 高度行已全部送完即停（文件尾部可能还有填充/附加数据）；
                    // 截断文件则由 bmp_len_cnt >= file_len 兜底，交给装载超时恢复
                    if ((pix_row >= height[10:0]) || (bmp_len_cnt >= file_len)) begin
                        state <= ST_IDLE;
                    end else begin
                        sd_sec_read_addr <= sd_sec_read_addr + 32'd1;
                    end
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
