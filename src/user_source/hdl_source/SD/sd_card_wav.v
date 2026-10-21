// ============================================================================
// sd_card_wav — TF 卡 WAV 文件解析与流式播放（100MHz 域）
//
// 功能：
//   1. bmp_read 扫描发现 WAV 起始扇区后，读取前 1~2 扇区解析 RIFF 头，
//      提取 fmt（采样率/声道/位深）与 data chunk 位置；
//   2. 校验通过后按 FIFO 水位持续从 SD 读取 PCM 写入跨时钟 FIFO
//      （100MHz 写 / 12.288MHz 读），供 wav_i2s_source 做 ASRC + I2S 输出；
//   3. 播放到 data 尾部自动循环；暂停（K1）时不读 SD，恢复后从断点继续；
//   4. 解析失败（非 PCM/非 16bit/采样率不支持/无 data）→ o_active 永久为 0，
//      音频回退系统测试音。
//
// SD 总线共享：与 bmp_read 共用 sd_card_top（sd_card_bmp 内仲裁）。
//   i_bus_grant=1 期间本模块独占总线；仲裁器保证 grant 撤销时本模块无在途扇区
//   （释放条件包含在途扇区完成）。
//
// 支持：16bit PCM，mono/stereo，8k/11.025k/16k/22.05k/24k/32k/44.1k/48k
// ============================================================================
module sd_card_wav #(
    parameter integer CLK_FREQ_HZ = 100_000_000
)(
    input  wire        clk,
    input  wire        rst,

    // 扫描结果（来自 bmp_read，同域）
    input  wire        i_scan_done,
    input  wire        i_wav_found,
    input  wire [31:0] i_wav_start_sector,

    // 暂停（100MHz 同步后电平）：1=暂停读取（FIFO 不再填充）
    input  wire        i_pause,

    // ---- SD 总线客户端（sd_card_bmp 内仲裁器接口）----
    output wire        o_bus_req,       // 请求 SD 总线
    input  wire        i_bus_grant,     // 1=本模块独占总线
    output reg         sd_sec_read,
    output reg  [31:0] sd_sec_addr,
    input  wire [7:0]  sd_sec_data,
    input  wire        sd_sec_data_valid,
    input  wire        sd_sec_read_end,

    // ---- FIFO 读端口（12.288MHz 域，FWFT：!empty 时 rd_data 有效，rd_en 消费）----
    input  wire        fifo_rd_clk,
    input  wire        fifo_rd_en,
    output wire [15:0] fifo_rd_data,
    output wire        fifo_empty,

    // ---- 状态输出（o_rate_step/o_stereo 在 o_active 置 1 前 ≥160ns 已稳定）----
    output reg         o_active,        // WAV 播放有效
    output reg  [32:0] o_rate_step,     // ASRC 步进（33bit，48k = 2^32）
    output reg         o_stereo         // 1=立体声
);

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------
localparam W_IDLE = 3'd0;   // 等扫描结果
localparam W_HDR  = 3'd1;   // 读头扇区并解析
localparam W_ARM  = 3'd2;   // 参数稳定间隔（跨域安全）
localparam W_PLAY = 3'd3;   // 播放补水
localparam W_DEAD = 3'd4;   // 解析失败，永久回退测试音

reg [2:0]  state;
reg [31:0] cur_sector;
reg [31:0] data_start_sector;  // data payload 起始扇区
reg [3:0]  arm_cnt;

// ---- 头解析寄存器 ----
reg [10:0] pbyte;            // 解析字节偏移 0..1023（跨 2 扇区连续）
reg [2:0]  pst;              // 解析子状态
reg [31:0] riff_size;
reg [31:0] chunk_size;
reg [31:0] chunk_cofs;       // chunk payload 内偏移
reg [7:0]  id0, id1, id2, id3;
reg [7:0]  id_sr;            // 'WAVE' 校验移位
reg        wave_ok;
reg        fmt_seen;
reg [15:0] fmt_format;
reg [15:0] fmt_ch;
reg [15:0] fmt_bps;
reg        data_seen;
reg [31:0] data_off;         // data payload 相对文件头字节偏移
reg [31:0] data_size;
reg [31:0] fmt_rate;         // 采样率（解析器独立装配）

// ---- 播放寄存器 ----
reg [8:0]  sec_byte_cnt;     // 扇区内字节 0..511
reg [31:0] byte_pos;         // data 有效字节计数（跨扇区累计）
reg        byte_ph;          // 16bit 组装相位 0=lo 1=hi
reg [7:0]  lo_byte;

// ---------------------------------------------------------------------------
// rate → ASRC step 查表（33bit 定点，0 = 不支持）
// ---------------------------------------------------------------------------
// 步进值按实际 audio_mclk 频率计算：f_mclk = 50MHz × 3/2 × 10/61 = 12.295082MHz
// 实际帧率 fs_actual = f_mclk / 256 = 48027.664Hz
// step = f_wav × 2^40 / f_mclk，确保 FIFO 消耗速率与 I2S 输出帧率精确匹配，
// 消除因频率偏差导致的周期性欠载爆音（突突声）和播放速度偏快
// ---------------------------------------------------------------------------
reg [3:0] rate_idx;   // 0-7 = 支持的采样率，8 = 未知/默认

always @(posedge clk or posedge rst) begin
    if (rst)
        rate_idx <= 4'd8;
    else case (fmt_rate)
        32'd8000 : rate_idx <= 4'd0;
        32'd11025: rate_idx <= 4'd1;
        32'd16000: rate_idx <= 4'd2;
        32'd22050: rate_idx <= 4'd3;
        32'd24000: rate_idx <= 4'd4;
        32'd32000: rate_idx <= 4'd5;
        32'd44100: rate_idx <= 4'd6;
        32'd48000: rate_idx <= 4'd7;
        default  : rate_idx <= 4'd8;
    endcase
end

function [32:0] idx2step;
    input [3:0] idx;
    begin
        case (idx)
            4'd0: idx2step = 33'd715415565;    // 8000
            4'd1: idx2step = 33'd985932076;    // 11025
            4'd2: idx2step = 33'd1430831131;   // 16000
            4'd3: idx2step = 33'd1971864153;   // 22050
            4'd4: idx2step = 33'd2146246697;   // 24000
            4'd5: idx2step = 33'd2861662263;   // 32000
            4'd6: idx2step = 33'd3943728306;   // 44100
            4'd7: idx2step = 33'd4292493394;   // 48000
            default: idx2step = 33'd0;
        endcase
    end
endfunction

wire [32:0] rate_step_val = idx2step(rate_idx);
wire        fmt_ok = fmt_seen && data_seen && wave_ok &&
                    (fmt_format == 16'd1) && (fmt_bps == 16'd16) &&
                    ((fmt_ch == 16'd1) || (fmt_ch == 16'd2)) &&
                    (rate_idx != 4'd8) && (data_size != 32'd0);

// fmt_ok 打一拍：头解析结束后参数已稳定，W_ARM 用寄存值决策，
// 避免 32bit data_size 比较器串入 state/cur_sector 使能（SWNS -0.028ns）
reg fmt_ok_r;
always @(posedge clk or posedge rst) begin
    if (rst)
        fmt_ok_r <= 1'b0;
    else
        fmt_ok_r <= fmt_ok;
end

// 总线请求：头解析或播放补水
// 阈值 = 停止线(1408) - 4 个扇区余量：grant 往返 + 在途最多 1 个扇区(256 字)，
// 保证 FIFO 最多到 ~1670 字，远离 2048 深度上限，杜绝满判丢字
wire [11:0] fifo_count;
assign o_bus_req = (state == W_HDR) ||
                   (state == W_PLAY && !i_pause && (fifo_count < 12'd1024));

// ---------------------------------------------------------------------------
// 头解析器（W_HDR 期间逐字节，LE 装配）
// ---------------------------------------------------------------------------
localparam P_RIFF    = 3'd0;   // 文件头 12 字节（RIFF 头结构固定）
localparam P_ID      = 3'd1;   // chunk id 4 字节
localparam P_SIZE    = 3'd2;   // chunk size 4 字节
localparam P_PAYLOAD = 3'd3;   // chunk payload（fmt 字段提取 / 其他跳过）

wire parse_en = (state == W_HDR) && sd_sec_data_valid;

// fmt_rate 独立装配（4 字节 LE 移位）
always @(posedge clk or posedge rst) begin
    if (rst)
        fmt_rate <= 32'd0;
    else if (parse_en && (pst == P_PAYLOAD) && !fmt_seen &&
             ({id3, id2, id1, id0} == "fmt ") && (chunk_cofs >= 32'd4) && (chunk_cofs <= 32'd7))
        fmt_rate <= {sd_sec_data, fmt_rate[31:8]};
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        pbyte <= 11'd0; pst <= P_RIFF; riff_size <= 32'd0;
        chunk_size <= 32'd0; chunk_cofs <= 32'd0;
        id0 <= 8'd0; id1 <= 8'd0; id2 <= 8'd0; id3 <= 8'd0;
        id_sr <= 8'd0; wave_ok <= 1'b0; fmt_seen <= 1'b0;
        fmt_format <= 16'd0; fmt_ch <= 16'd0; fmt_bps <= 16'd0;
        data_seen <= 1'b0; data_off <= 32'd0; data_size <= 32'd0;
    end else if (parse_en) begin
        pbyte <= pbyte + 11'd1;
        case (pst)
            P_RIFF: begin
                case (pbyte[3:0])
                    4'd4, 4'd5, 4'd6, 4'd7:
                        riff_size <= {sd_sec_data, riff_size[31:8]};
                    4'd8:  id_sr <= sd_sec_data;                          // 'W'
                    4'd9:  if (id_sr == "W") id_sr <= sd_sec_data;        // 'A'
                    4'd10: if (id_sr == "A") id_sr <= sd_sec_data;        // 'V'
                    4'd11: if (id_sr == "V" && sd_sec_data == "E") wave_ok <= 1'b1;
                    default: ;
                endcase
                if (pbyte == 11'd11)
                    pst <= P_ID;
            end

            P_ID: begin
                {id3, id2, id1, id0} <= {id2, id1, id0, sd_sec_data};
                if (pbyte[1:0] == 2'd3)
                    pst <= P_SIZE;
            end

            P_SIZE: begin
                if (pbyte[1:0] == 2'd3) begin
                    chunk_size <= {sd_sec_data, chunk_size[31:8]};
                    chunk_cofs <= 32'd0;
                    if ({id3, id2, id1, id0} == "data") begin
                        data_seen <= 1'b1;
                        data_off  <= pbyte + 11'd1;   // size 第 4 字节后即 payload 起点
                        data_size <= {sd_sec_data, chunk_size[31:8]};
                    end
                    pst <= P_PAYLOAD;
                end else begin
                    chunk_size <= {sd_sec_data, chunk_size[31:8]};
                end
            end

            P_PAYLOAD: begin
                if (!fmt_seen && ({id3, id2, id1, id0} == "fmt ")) begin
                    case (chunk_cofs)
                        32'd0:  fmt_format <= {fmt_format[15:8], sd_sec_data};
                        32'd1:  fmt_format <= {sd_sec_data, fmt_format[7:0]};
                        32'd2:  fmt_ch      <= {fmt_ch[15:8], sd_sec_data};
                        32'd3:  fmt_ch      <= {sd_sec_data, fmt_ch[7:0]};
                        32'd14: fmt_bps     <= {fmt_bps[15:8], sd_sec_data};
                        32'd15: begin
                            fmt_bps  <= {sd_sec_data, fmt_bps[7:0]};
                            fmt_seen <= 1'b1;
                        end
                        default: ;
                    endcase
                end
                if (chunk_cofs + 32'd1 >= chunk_size)
                    pst <= P_ID;      // 下一个 chunk
                else
                    chunk_cofs <= chunk_cofs + 32'd1;
            end

            default: pst <= P_RIFF;
        endcase
    end
end

// ---------------------------------------------------------------------------
// 主状态机
// ---------------------------------------------------------------------------
wire [8:0] data_skip_eff = (cur_sector == data_start_sector) ? data_off[8:0] : 9'd0;
// in_data_zone：byte_pos < data_size 的寄存副本（与 byte_pos 同拍流水更新），
// 避免 32bit 顺序比较长链直驱 byte_pos 的时钟使能（SWNS -0.968ns）
reg        in_data_zone;
wire       byte_valid = (state == W_PLAY) && sd_sec_data_valid &&
                        (sec_byte_cnt >= data_skip_eff) && in_data_zone;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state       <= W_IDLE;
        sd_sec_read <= 1'b0;
        sd_sec_addr <= 32'd0;
        cur_sector  <= 32'd0;
        data_start_sector <= 32'd0;
        arm_cnt     <= 4'd0;
        o_active    <= 1'b0;
        o_rate_step <= 33'd0;
        o_stereo    <= 1'b0;
        sec_byte_cnt<= 9'd0;
        byte_pos    <= 32'd0;
        byte_ph     <= 1'b0;
        in_data_zone<= 1'b0;
    end else begin
        case (state)
            W_IDLE: begin
                sd_sec_read <= 1'b0;
                if (i_scan_done && i_wav_found) begin
                    cur_sector  <= i_wav_start_sector;
                    sd_sec_addr <= i_wav_start_sector;
                    state       <= W_HDR;
                end
            end

            W_HDR: begin
                // 解析期间持续读（最多 2 扇区 / 1024 字节；data chunk 头出现即停）
                if (i_bus_grant && !data_seen && (pbyte < 11'd1023))
                    sd_sec_read <= 1'b1;
                else
                    sd_sec_read <= 1'b0;

                if (sd_sec_read_end) begin
                    if (data_seen || (pbyte >= 11'd1023)) begin
                        state <= W_ARM;
                        arm_cnt <= 4'd0;
                        sd_sec_read <= 1'b0;
                    end else begin
                        sd_sec_addr <= sd_sec_addr + 32'd1;   // 读第 2 扇区
                    end
                end
            end

            W_ARM: begin
                if (arm_cnt == 4'd0) begin
                    // 先锁参数（提前于 active ≥15 拍，保证跨域采样稳定）
                    o_rate_step       <= rate_step_val;
                    o_stereo          <= (fmt_ch == 16'd2);
                    data_start_sector <= i_wav_start_sector + (data_off >> 9);
                end else if (arm_cnt == 4'd15) begin
                    if (fmt_ok_r) begin
                        cur_sector   <= i_wav_start_sector + (data_off >> 9);
                        byte_pos     <= 32'd0;
                        in_data_zone <= 1'b1;    // data_size != 0（fmt_ok 已保证）
                        sec_byte_cnt <= 9'd0;
                        byte_ph      <= 1'b0;
                        state        <= W_PLAY;
                        o_active     <= 1'b1;
                    end else begin
                        state <= W_DEAD;
                    end
                end
                arm_cnt <= arm_cnt + 4'd1;
            end

            W_PLAY: begin
                sd_sec_read <= i_bus_grant && !i_pause && (fifo_count < 12'd1408);
                sd_sec_addr <= cur_sector;

                if (sd_sec_read_end) begin
                    sec_byte_cnt <= 9'd0;
                    // sd_card_sec_read_write 在 read_end 的下一拍(S_WAIT_READ_WRITE)
                    // 就锁存 sd_sec_read_addr；必须在本拍把地址推到下一扇区，
                    // 否则下一拍锁到的是刚读完的旧地址 → 每个扇区被读两遍(周期性突突声)
                    // !in_data_zone 等价于 byte_pos >= data_size，避免 32bit
                    // 比较器串进 read_end 分支（SWNS -0.028ns）
                    if (!in_data_zone) begin
                        cur_sector   <= data_start_sector;   // 循环回 data 起点
                        sd_sec_addr  <= data_start_sector;
                        byte_pos     <= 32'd0;
                        in_data_zone <= 1'b1;
                        byte_ph      <= 1'b0;
                    end else begin
                        cur_sector   <= cur_sector + 32'd1;
                        sd_sec_addr  <= cur_sector + 32'd1;
                    end
                end else if (sd_sec_data_valid) begin
                    sec_byte_cnt <= sec_byte_cnt + 9'd1;
                    if (byte_valid) begin
                        byte_pos     <= byte_pos + 32'd1;
                        in_data_zone <= ((byte_pos + 32'd1) < data_size);
                        byte_ph      <= ~byte_ph;
                    end
                end
            end

            W_DEAD: begin
                sd_sec_read <= 1'b0;
                o_active    <= 1'b0;
            end

            default: state <= W_IDLE;
        endcase
    end
end

// ---------------------------------------------------------------------------
// 16bit 小端组装 + FIFO 写（hi 字节拍完成一个样本字）
// 写通道打一拍：byte_valid 含 32bit 扇区比较长组合链，直接驱动 2048 深 RAM
// 写使能译码会超 100MHz 时序（SWNS -5.015ns），故先寄存 we/wd 再写 RAM
// ---------------------------------------------------------------------------
wire       fifo_we_raw = byte_valid && byte_ph;
wire [15:0] fifo_wd_raw = {sd_sec_data, lo_byte};

reg        fifo_we;
reg [15:0] fifo_wd;

always @(posedge clk or posedge rst) begin
    if (rst)
        lo_byte <= 8'd0;
    else if (byte_valid && !byte_ph)
        lo_byte <= sd_sec_data;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        fifo_we <= 1'b0;
        fifo_wd <= 16'd0;
    end else begin
        fifo_we <= fifo_we_raw;
        fifo_wd <= fifo_wd_raw;
    end
end

// ---------------------------------------------------------------------------
// 跨时钟 FIFO 存储：2048 x 16bit，显式例化 BRAM9K 原语（见文件末尾）
// BRAM NOREG 同步读：读地址给出后下一拍 dob 有效；读侧取数流水将地址保持
// 3 拍再锁存，兼容 1 拍延迟的同时也容忍 0/2 拍延迟
// （ramstyle 属性对该深度失效，SYN-1027 仍推成 DRAM 吃掉 ~4k LUT 致布线冲突）
// ---------------------------------------------------------------------------
wire [15:0] fifo_rd_dob;


// ---- 写域 ----
reg  [11:0] wbin;
wire [11:0] wgray = wbin ^ (wbin >> 1);
reg  [11:0] rbin;                          // 读域指针（声明提前：写域同步引用 rgray）
wire [11:0] rgray = rbin ^ (rbin >> 1);
reg  [11:0] rgray_w1, rgray_w2;
// gray → binary 必须逐位递推；仅做 g^(g>>1) 只对 2bit 以内成立，
// 指针增大后水位计数会严重失真（曾导致补水阈值误判、FIFO 假满/欠载）
function [11:0] gray2bin;
    input [11:0] g;
    integer k;
    begin
        gray2bin[11] = g[11];
        for (k = 10; k >= 0; k = k - 1)
            gray2bin[k] = gray2bin[k+1] ^ g[k];
    end
endfunction
wire [11:0] rbin_w  = gray2bin(rgray_w2);
// 水位计数寄存一拍：gray2bin + 减法链仅到寄存器 D，不再直驱下游比较/RAM 使能
reg  [11:0] wcount_q;
always @(posedge clk or posedge rst) begin
    if (rst)
        wcount_q <= 12'd0;
    else
        wcount_q <= wbin - rbin_w;
end
assign fifo_count = wcount_q;
// 判满：写指针下一跳 gray 与同步后读 gray 高 2 位取反比较（无 gray2bin/减法）
wire [11:0] wbin_next  = wbin + 12'd1;
wire [11:0] wgray_next = wbin_next ^ (wbin_next >> 1);
wire fifo_full = (wgray_next == {~rgray_w2[11:10], rgray_w2[9:0]});

// 第二级写流水：判满结果（full_q）与水位硬上限（wcount_q != 2047）合并后
// 再寄存一拍，RAM 写使能路径上只剩寄存器输出的短逻辑，切断
// "wbin→加法→gray 比较→RAM 译码" 超长链（SWNS -2.987ns）
reg        full_q;
reg        fifo_we2;
reg [15:0] fifo_wd2;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        full_q   <= 1'b0;
        fifo_we2 <= 1'b0;
        fifo_wd2 <= 16'd0;
    end else begin
        full_q   <= fifo_full;
        fifo_we2 <= fifo_we && !full_q && (wcount_q != 12'd2047);
        fifo_wd2 <= fifo_wd;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rgray_w1 <= 12'd0;
        wbin     <= 12'd0;
    end else begin
        rgray_w1 <= rgray;
        if (fifo_we2) begin
            // BRAM A 口：wea=fifo_we2, dia=fifo_wd2, addra=wbin（例化在文件末尾）
            wbin <= wbin + 12'd1;
        end
    end
end
always @(posedge clk)
    rgray_w2 <= rgray_w1;

// ---- 读域（fifo_rd_clk）----
// 两级输出队列 + 单笔取数流水：
//   q0 为队首（fifo_rd_data），q1 为队尾；fifo_rd_en 当拍消费 q0。
//   一次取数占 3 拍（发出 / 地址保持 / 锁存），地址全程不变，
//   兼容 BRAM 0/1/2 拍读延迟（EG_LOGIC_BRAM NOREG 为 1 拍）。
//   旧实现 front_v=0 的拍会重复发读地址，且 dob_valid 到达时无条件覆盖
//   front_d（未消费的队首被下一字冲掉）→ 隔字丢失、播放破碎。
reg  [11:0] wgray_r1, wgray_r2;
reg  [15:0] q0_d, q1_d;
reg  [1:0]  q_v;                           // 队列有效字数 0..2
reg  [1:0]  fch;                           // 0=空闲 1=取数第1拍 2=取数第2拍(锁存)
wire        fifo_empty_i = (rgray == wgray_r2);   // 无未装载数据

wire        push = (fch == 2'd2);                     // 本拍末锁存 dob
wire        pop  = fifo_rd_en && (q_v != 2'd0);
wire        fetch_start = (fch == 2'd0) && !fifo_empty_i &&
                          (pop || (q_v < 2'd2));

assign fifo_empty   = (q_v == 2'd0);
assign fifo_rd_data = q0_d;

// 读域采用同步复位：rst 由 100MHz 域生成，异步复位跨到 fifo_rd_clk 域
// 的 recovery/removal 检查恒违例（SWNS -2.162ns × 10 条），同步化消除
always @(posedge fifo_rd_clk) begin
    if (rst) begin
        wgray_r1 <= 12'd0;
        wgray_r2 <= 12'd0;
        rbin     <= 12'd0;
        q0_d     <= 16'd0;
        q1_d     <= 16'd0;
        q_v      <= 2'd0;
        fch      <= 2'd0;
    end else begin
        wgray_r1 <= wgray;
        wgray_r2 <= wgray_r1;

        // 取数流水：地址(rbin)保持 3 拍不变，第 3 拍末锁存并推进读指针
        case (fch)
            2'd0: if (fetch_start) fch <= 2'd1;
            2'd1: fch <= 2'd2;
            2'd2: begin
                fch  <= 2'd0;
                rbin <= rbin + 12'd1;
            end
            default: fch <= 2'd0;
        endcase

        case ({push, pop})
            2'b10: begin                      // 只入队
                if (q_v == 2'd0) begin
                    q0_d <= fifo_rd_dob;
                    q_v  <= 2'd1;
                end else begin
                    q1_d <= fifo_rd_dob;
                    q_v  <= 2'd2;
                end
            end
            2'b01: begin                      // 只出队
                if (q_v == 2'd2) begin
                    q0_d <= q1_d;
                    q_v  <= 2'd1;
                end else begin
                    q_v  <= 2'd0;
                end
            end
            2'b11: begin                      // 同拍出入队
                if (q_v == 2'd2) begin
                    q0_d <= q1_d;
                    q1_d <= fifo_rd_dob;
                    q_v  <= 2'd2;
                end else begin
                    q0_d <= fifo_rd_dob;
                    q_v  <= 2'd1;
                end
            end
            default: ;
        endcase
    end
end

// ---------------------------------------------------------------------------
// FIFO 存储体：2048x16 真双口 BRAM（写 clk / 读 fifo_rd_clk）
// ---------------------------------------------------------------------------
EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(16), .ADDR_WIDTH_A(11),
    .DATA_WIDTH_B(16), .ADDR_WIDTH_B(11),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
    .RESETMODE("SYNC"), .IMPLEMENT("9K")
) u_wav_fifo_ram (
    .dia(fifo_wd2), .addra(wbin[10:0]), .cea(1'b1), .ocea(1'b1),
    .clka(clk), .wea(fifo_we2), .rsta(1'b0), .bea(1'b1),
    .dib(16'd0), .addrb(rbin[10:0]), .ceb(1'b1), .oceb(1'b1),
    .clkb(fifo_rd_clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
    .doa(), .dob(fifo_rd_dob)
);

endmodule
