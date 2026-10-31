// ============================================================================
// egv_reader — EGV1 视频容器裸扇区读取器（sd_card_clk 100MHz 域）
//
// 按 24fps 节拍，每帧读入 BLOCK_SEC(201) 个扇区：
//   · 扇区号 i 满足 i % AUDIO_MOD == AUDIO_MOD-1 → 音频区（16 sector）
//   · 其余扇区 → 视频区 RGB565 大端（185 sector = 320*148 像素）
//
// 段表来源（优先级从高到低）：
//   1. 运行时解析：bmp_read 扫描按 "EGV1" 魔数找到容器起始 LBA 后，
//      本模块在首次播放前读一次容器头，动态装载段表/帧数。
//      容器在卡上搬动/重新封装后无需重新综合，彻底消除"段表过期→图像错位"。
//   2. 编译期常量（egv_cfg.vh）：扫描窗口内没找到容器（例如视频在 64MB 之后）
//      或头部校验失败时回退，行为与旧版一致。
// 头部校验：魔数/版本/分辨率/fps/块几何/音频参数 + run0 物理 LBA == 发现 LBA
//          （后一条可识别"整个文件被拷到别处但头里还是旧段表"的情况）。
//
// 节拍：一帧 = FRAME_CYC 拍（100MHz/24fps）。读 201 扇区约 33ms，
// 余下 ~8.6ms 为帧间空隙。音频按整帧预存进 FIFO，播放端与显示端
// 因此天然对齐（见 video/egv_audio_fifo.v）。
// ============================================================================
`timescale 1ns/1ps
`include "egv_cfg.vh"

module egv_reader #(
    parameter [22:0]  FRAME_CYC = 23'd4_166_667,   // 100MHz / 24fps
    parameter integer AUD_BYTES = `EGV_AUDIO_BYTES,
    parameter integer BLOCK_SEC = `EGV_BLOCK_SECTORS
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        i_play,          // 播放电平（准静态，已跨域同步）
    input  wire        i_sd_ready,      // SD 初始化完成
    input  wire        i_fill_ready,    // 帧填充器空闲（可接收新的帧起始）
    input  wire        i_scan_done,     // 扫描完成（EGV1 位置已确定）
    input  wire        i_egv_found,     // 扫描发现 EGV1 容器
    input  wire [31:0] i_egv_lba,       // EGV1 起始扇区（容器头所在扇区）

    // ---- SD 扇区读客户端 ----
    output reg         o_sd_read,
    output reg  [31:0] o_sd_addr,
    output reg  [15:0] o_sd_count,      // 本批连续扇区数（CMD18 流式读）
    input  wire [7:0]  i_sd_data,
    input  wire        i_sd_data_valid,
    input  wire        i_sd_read_end,

    // ---- 视频像素流（RGB565，每像素一拍）----
    output reg         o_pix_en,
    output reg  [15:0] o_pix,
    output reg         o_frame_start,   // 帧起始单拍脉冲

    // ---- 音频字节流（s16le 交织，每帧恰好 AUD_BYTES 字节）----
    output reg         o_aud_en,
    output reg  [7:0]  o_aud_byte,
    output reg         o_aud_fstart,

    // ---- 状态 ----
    output reg  [15:0] o_frame_no,
    output reg         o_active
);

    localparam [2:0] S_IDLE    = 3'd0,
                     S_HDR     = 3'd1,   // 读容器头扇区
                     S_HDR_CHK = 3'd2,   // 校验并装载段表
                     S_FWAIT   = 3'd3,
                     S_SEC     = 3'd4;

    localparam [7:0]  LAST_SEC   = BLOCK_SEC - 1;
    localparam [3:0]  AMOD_LAST  = `EGV_AUDIO_MOD - 1;
    localparam [12:0] AUD_BYTES_V = AUD_BYTES;
    localparam [15:0] BLOCK_SEC_V = BLOCK_SEC;
    localparam [15:0] LAST_FRAME = `EGV_FRAMES - 1;

    // 容器头固定字段（校验用，布局见 tools/video/mp4_to_egv.py）
    localparam [31:0] HDR_W      = `EGV_W;
    localparam [31:0] HDR_H      = `EGV_H;
    localparam [31:0] HDR_FPS    = `EGV_FPS;
    localparam [31:0] HDR_VBYTES = `EGV_VIDEO_BYTES;
    localparam [31:0] HDR_ABYTES = `EGV_AUDIO_BYTES;
    localparam [31:0] HDR_ARATE  = 32'd48000;
    localparam [31:0] HDR_BS     = BLOCK_SEC;
    localparam [31:0] HDR_AMOD   = `EGV_AUDIO_MOD;

    reg [2:0]  st;
    reg [7:0]  sec_i;         // 0..BLOCK_SEC-1
    reg [3:0]  amod_cnt;      // 0..AUDIO_MOD-1
    reg        byte_ph;       // 0=高字节先（视频）/低字节先（音频）
    reg [7:0]  byte_hi;
    reg [12:0] aud_cnt;       // 本帧已送出的有效音频字节数
    reg [31:0] phys;          // 当前物理 LBA
    reg [22:0] ftmr;
    reg        first;
    reg        stop_req;
    reg        eof_stop;      // 已播完整个容器：停在最后一帧，等 K1 重新启动
    reg [15:0] nb;            // 当前批剩余扇区数（含正在读的扇区）
    reg [1:0]  run_i;         // 当前物理段号（0..3）
    reg [19:0] run_rem;       // 本段剩余扇区数（含下一个要读的扇区），饱和于 RUN_MAX

    // ---- 运行时容器头解析 ----
    reg [8:0]  h_idx;         // 头内字节偏移 0..511
    reg [31:0] h_word;        // 最近 4 字节（LE 装配）
    reg [31:0] h_frames;
    reg [15:0] h_nruns;
    reg        hdr_bad;
    reg        hdr_done;      // 已尝试解析（成功/失败都置位，避免每次播放重读）
    reg        rt_ok;         // 解析成功：使用运行时段表
    reg [31:0] rt_rp0, rt_rp1, rt_rp2, rt_rp3;
    reg [19:0] rt_len0, rt_len1, rt_len2, rt_len3;
    reg [15:0] rt_last_frame;

    // 段长必须精确：中间段可达数十万扇区（本容器 run1 = 385024），
    // 16bit 饱和会让"段结束"提前触发 → 中途误跳到 RP2，读到错位的数据流。
    // 20bit 上限 1048575 扇区（512MB），足够覆盖任意单段；批大小仍只需与 201 比较。
    localparam [19:0] RUN_MAX  = 20'hFFFFF;
    localparam [31:0] RUN0_SPAN = `EGV_RG1 - `EGV_RG0;
    localparam [31:0] RUN1_SPAN = `EGV_RG2 - `EGV_RG1;
    // 第 3 段：3 段容器时 RG3 为 0xFFFFFFFF 哨兵 → 溢出后饱和成 RUN_MAX，
    // 4 段容器时得到真实段长（旧版在这里固定 RUN_MAX，run3 永远读不到）
    localparam [31:0] RUN2_SPAN = `EGV_RG3 - `EGV_RG2;
    localparam [19:0] RUN0_LEN = (RUN0_SPAN > 32'd1048575) ? RUN_MAX : RUN0_SPAN[19:0];
    localparam [19:0] RUN1_LEN = (RUN1_SPAN > 32'd1048575) ? RUN_MAX : RUN1_SPAN[19:0];
    localparam [19:0] RUN2_LEN = (RUN2_SPAN > 32'd1048575) ? RUN_MAX : RUN2_SPAN[19:0];

    // 运行时段表有效时覆盖编译期常量（rt_ok 为准静态寄存器）
    wire [15:0] last_frame_v = rt_ok ? rt_last_frame : LAST_FRAME;
    wire        frame_last   = (o_frame_no == last_frame_v);

    wire is_audio = (amod_cnt == AMOD_LAST);

    // ---- 段表推进：逐扇区 +1，跨段时跳到下一段物理起点 ----
    // 20bit 计数器代替 gsec 的 32bit 减法，批大小组合逻辑由 13.4ns 降到 ~6ns
    wire        run_xn       = (run_rem == 20'd1);
    wire [19:0] run_len_next = (run_i == 2'd0) ? (rt_ok ? rt_len1 : RUN1_LEN) :
                               (run_i == 2'd1) ? (rt_ok ? rt_len2 : RUN2_LEN) :
                                                 (rt_ok ? rt_len3 : RUN_MAX);
    wire [19:0] run_rem_n    = run_xn ? run_len_next : (run_rem - 20'd1);
    wire [31:0] rp_next      = (run_i == 2'd0) ? (rt_ok ? rt_rp1 : `EGV_RP1) :
                               (run_i == 2'd1) ? (rt_ok ? rt_rp2 : `EGV_RP2) :
                                                 (rt_ok ? rt_rp3 : `EGV_RP3);
    wire [31:0] phys_nx      = run_xn ? rp_next : (phys + 32'd1);
    wire [31:0] start_phys   = rt_ok ? rt_rp0 : `EGV_RP0;
    wire [19:0] start_rem    = rt_ok ? rt_len0 : RUN0_LEN;

    // ---- 批大小：min(本段剩余, 本帧剩余) ----
    // CMD18 连续读只有段内物理地址连续，因此每跨一段就结束本批、从新段起点重开。
    // 帧起始时 sec_i 还是上一帧的末值，故按"整帧剩余"算。
    // 段剩余只需与 201 比较，先饱和到 16bit 再做窄比较（避免 20bit 宽比较进批大小链）
    function [15:0] sat16;
        input [19:0] v;
        begin
            sat16 = (|v[19:16]) ? 16'hFFFF : v[15:0];
        end
    endfunction

    function [19:0] sat20;
        input [31:0] v;
        begin
            sat20 = (|v[31:20]) ? RUN_MAX : v[19:0];
        end
    endfunction

    wire frames_ok = (h_frames != 32'd0) && (h_frames <= 32'd65_536);
    wire nruns_ok  = (h_nruns >= 16'd1) && (h_nruns <= 16'd4);
    // run0 物理起点必须等于"发现 LBA + 1"（文件首扇区是容器头）：
    // 整个文件被拷到别处时头里仍是旧段表，靠这条拒绝
    wire phys0_ok  = (rt_rp0 == (i_egv_lba + 32'd1));
    wire hdr_ok    = !hdr_bad && frames_ok && nruns_ok && phys0_ok;
    // run_rem 只在扇区结束才更新，故下一拍的段剩余可每拍预算并寄存：
    // 批大小链变成 寄存器→16bit 比较→mux，20bit 减法只到寄存器（原 8 级 10.1ns）
    reg [19:0] run_rem_n_q;
    reg [15:0] rem_n_s_q;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            run_rem_n_q <= RUN0_LEN;
            rem_n_s_q   <= 16'hFFFF;
        end else begin
            run_rem_n_q <= run_xn ? run_len_next : (run_rem - 20'd1);
            rem_n_s_q   <= sat16(run_xn ? run_len_next : (run_rem - 20'd1));
        end
    end
    wire [15:0] rem_s        = sat16(run_rem);
    wire [15:0] batch_s = (rem_s < BLOCK_SEC_V) ? rem_s : BLOCK_SEC_V;
    wire [15:0] frame_left_n = BLOCK_SEC_V - {8'd0, sec_i} - 16'd1;
    wire [15:0] batch_n = (rem_n_s_q < frame_left_n) ? rem_n_s_q : frame_left_n;

    wire frame_start_now = (st == S_FWAIT) && i_play && !stop_req && i_fill_ready &&
                           (first || (ftmr >= FRAME_CYC));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st           <= S_IDLE;
            o_sd_read    <= 1'b0;
            o_sd_addr    <= 32'd0;
            o_sd_count   <= BLOCK_SEC_V;
            nb           <= 16'd0;
            o_pix_en     <= 1'b0;
            o_pix        <= 16'd0;
            o_frame_start<= 1'b0;
            o_aud_en     <= 1'b0;
            o_aud_byte   <= 8'd0;
            o_aud_fstart <= 1'b0;
            o_frame_no   <= 16'd0;
            o_active     <= 1'b0;
            sec_i        <= 8'd0;
            amod_cnt     <= 4'd0;
            byte_ph      <= 1'b0;
            byte_hi      <= 8'd0;
            aud_cnt      <= 13'd0;
            phys         <= `EGV_RP0;
            run_i        <= 2'd0;
            run_rem      <= RUN0_LEN;
            ftmr         <= 23'd0;
            first        <= 1'b1;
            stop_req     <= 1'b0;
            eof_stop     <= 1'b0;
        end else begin
            o_pix_en     <= 1'b0;
            o_frame_start<= 1'b0;
            o_aud_en     <= 1'b0;
            o_aud_fstart <= 1'b0;

            if (!i_play)
                stop_req <= 1'b1;
            else if (st == S_IDLE)
                stop_req <= 1'b0;

            // 播完整个容器后停在最后一帧；松开 K1 后才能重新从头播
            if (!i_play)
                eof_stop <= 1'b0;

            // 帧定时器：帧起点清零，到 FRAME_CYC 饱和
            if (frame_start_now)
                ftmr <= 23'd0;
            else if (ftmr < FRAME_CYC)
                ftmr <= ftmr + 23'd1;

            case (st)
            // ------------------------------------------------------------
            S_IDLE: begin
                o_sd_read <= 1'b0;
                o_active  <= 1'b0;
                // 等扫描完成再起播：EGV1 的物理位置由扫描魔数确定，
                // 提前用编译期段表可能读到别的文件（图像错位/音频噪声）
                if (i_play && !stop_req && !eof_stop && i_sd_ready && i_scan_done) begin
                    if (i_egv_found && !hdr_done) begin
                        // 首次播放：先读一次容器头，动态装载段表/帧数
                        // h_idx/h_word/hdr_bad 由解析块在 S_IDLE 清零（单驱动）
                        o_sd_read  <= 1'b1;
                        o_sd_addr  <= i_egv_lba;
                        o_sd_count <= 16'd1;
                        st         <= S_HDR;
                    end else begin
                        phys    <= start_phys;
                        run_i   <= 2'd0;
                        run_rem <= start_rem;
                        sec_i   <= 8'd0;
                        aud_cnt <= 13'd0;
                        first   <= 1'b1;
                        o_frame_no <= 16'd0;
                        o_active<= 1'b1;
                        o_sd_count <= BLOCK_SEC_V;
                        nb      <= 16'd0;
                        st      <= S_FWAIT;
                    end
                end
            end
            // ------------------------------------------------------------
            S_HDR: begin
                // 单扇区读（CMD17）；头解析在并行 always 块里逐字节完成
                if (i_sd_read_end) begin
                    o_sd_read <= 1'b0;
                    st        <= S_HDR_CHK;
                end
            end
            // ------------------------------------------------------------
            S_HDR_CHK: begin
                o_sd_read <= 1'b0;
                if (i_play && !stop_req) begin
                    // 头有效用运行时段表，否则回退编译期常量（旧行为）
                    phys    <= hdr_ok ? rt_rp0 : `EGV_RP0;
                    run_i   <= 2'd0;
                    run_rem <= hdr_ok ? rt_len0 : RUN0_LEN;
                    sec_i   <= 8'd0;
                    aud_cnt <= 13'd0;
                    first   <= 1'b1;
                    o_frame_no <= 16'd0;
                    o_active<= 1'b1;
                    o_sd_count <= BLOCK_SEC_V;
                    nb      <= 16'd0;
                    st      <= S_FWAIT;
                end else
                    st <= S_IDLE;
            end
            // ------------------------------------------------------------
            S_FWAIT: begin
                if (!i_play || stop_req) begin
                    o_active  <= 1'b0;
                    o_sd_read <= 1'b0;
                    st        <= S_IDLE;
                end else if (frame_start_now) begin
                    first        <= 1'b0;
                    sec_i        <= 8'd0;
                    amod_cnt     <= 4'd0;
                    byte_ph      <= 1'b0;
                    aud_cnt      <= 13'd0;
                    o_frame_start<= 1'b1;
                    o_aud_fstart <= 1'b1;
                    o_sd_read    <= 1'b1;
                    o_sd_addr    <= phys;
                    o_sd_count   <= batch_s;
                    nb           <= batch_s;
                    st           <= S_SEC;
                end
            end
            // ------------------------------------------------------------
            S_SEC: begin
                if (i_sd_data_valid) begin
                    if (is_audio) begin
                        // s16le：低字节先到
                        if (aud_cnt < AUD_BYTES_V) begin
                            o_aud_en   <= 1'b1;
                            o_aud_byte <= i_sd_data;
                            aud_cnt    <= aud_cnt + 13'd1;
                        end
                    end else begin
                        // RGB565 大端：高字节先到
                        byte_ph <= ~byte_ph;
                        if (!byte_ph)
                            byte_hi <= i_sd_data;
                        else begin
                            o_pix_en <= 1'b1;
                            o_pix    <= {byte_hi, i_sd_data};
                        end
                    end
                end

                if (i_sd_read_end) begin
                    phys    <= phys_nx;
                    run_rem <= run_rem_n;
                    run_i   <= run_xn ? (run_i + 2'd1) : run_i;
                    byte_ph <= 1'b0;                 // 512B 偶数长度，保险对齐
                    if (sec_i == LAST_SEC) begin
                        o_sd_read  <= 1'b0;
                        o_frame_no <= o_frame_no + 16'd1;
                        if (frame_last) begin
                            // 最后一帧结束：停止取流，画面冻结在最后一帧
                            o_active <= 1'b0;
                            st       <= S_IDLE;
                            eof_stop <= 1'b1;
                        end else
                            st <= S_FWAIT;
                        if (!i_play)
                            stop_req <= 1'b1;
                    end else begin
                        sec_i    <= sec_i + 8'd1;
                        amod_cnt <= (amod_cnt == AMOD_LAST) ? 4'd0 : amod_cnt + 4'd1;
                        if (nb <= 16'd1) begin
                            // 本批读空：从下一段/下一批起点重开一条 CMD18
                            o_sd_addr  <= phys_nx;
                            o_sd_count <= batch_n;
                            nb         <= batch_n;
                        end else begin
                            o_sd_count <= nb - 16'd1;
                            nb         <= nb - 16'd1;
                        end
                    end
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // 容器头捕获（S_HDR 期间逐字节，LE）
    //   0..3 'EGV1'   4..5 ver   6..7 w   8..9 h   10..11 fps
    //   12..15 frames             16..19 block_bytes（不校验）
    //   20..23 video_bytes        24..27 audio_bytes
    //   28..29 arate  30..31 ach  32..33 block_sectors  34..35 audio_mod
    //   40..41 n_runs 44+12i 三段：logical(跳过) / nsec / phys
    // 校验字段直接和常量比较，不占寄存器；只保留段表/帧数等真正要用的值。
    // ------------------------------------------------------------------
    wire        hdr_byte_en = (st == S_HDR) && i_sd_data_valid;
    // LE 装配：最新字节进最高位，h_val 即最近 4 字节按小端拼好的 u32
    wire [31:0] h_val       = {i_sd_data, h_word[31:8]};

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            h_idx         <= 9'd0;
            h_word        <= 32'd0;
            h_frames      <= 32'd0;
            h_nruns       <= 16'd0;
            hdr_bad       <= 1'b0;
            hdr_done      <= 1'b0;
            rt_ok         <= 1'b0;
            rt_rp0        <= 32'd0;
            rt_rp1        <= 32'd0;
            rt_rp2        <= 32'd0;
            rt_rp3        <= 32'd0;
            rt_len0       <= 20'd0;
            rt_len1       <= 20'd0;
            rt_len2       <= 20'd0;
            rt_len3       <= 20'd0;
            rt_last_frame <= 16'd0;
        end else begin
            if (st == S_IDLE) begin
                // 头读取起始：S_IDLE 期间清零解析游标（FSM 块不再驱动这些寄存器）
                h_idx   <= 9'd0;
                h_word  <= 32'd0;
                hdr_bad <= 1'b0;
            end else if (hdr_byte_en) begin
                h_idx  <= h_idx + 9'd1;
                h_word <= {i_sd_data, h_word[31:8]};
                case (h_idx)
                    9'd0:  hdr_bad <= hdr_bad | (i_sd_data != "E");
                    9'd1:  hdr_bad <= hdr_bad | (i_sd_data != "G");
                    9'd2:  hdr_bad <= hdr_bad | (i_sd_data != "V");
                    9'd3:  hdr_bad <= hdr_bad | (i_sd_data != "1");
                    9'd4:  hdr_bad <= hdr_bad | (i_sd_data != 8'd2);       // ver = 2
                    9'd5:  hdr_bad <= hdr_bad | (i_sd_data != 8'd0);
                    9'd6:  hdr_bad <= hdr_bad | (i_sd_data != HDR_W[7:0]);
                    9'd7:  hdr_bad <= hdr_bad | (i_sd_data != HDR_W[15:8]);
                    9'd8:  hdr_bad <= hdr_bad | (i_sd_data != HDR_H[7:0]);
                    9'd9:  hdr_bad <= hdr_bad | (i_sd_data != HDR_H[15:8]);
                    9'd10: hdr_bad <= hdr_bad | (i_sd_data != HDR_FPS[7:0]);
                    9'd11: hdr_bad <= hdr_bad | (i_sd_data != HDR_FPS[15:8]);
                    9'd12: h_frames[7:0]   <= i_sd_data;
                    9'd13: h_frames[15:8]  <= i_sd_data;
                    9'd14: h_frames[23:16] <= i_sd_data;
                    9'd15: h_frames[31:24] <= i_sd_data;
                    9'd20: hdr_bad <= hdr_bad | (i_sd_data != HDR_VBYTES[7:0]);
                    9'd21: hdr_bad <= hdr_bad | (i_sd_data != HDR_VBYTES[15:8]);
                    9'd22: hdr_bad <= hdr_bad | (i_sd_data != HDR_VBYTES[23:16]);
                    9'd23: hdr_bad <= hdr_bad | (i_sd_data != HDR_VBYTES[31:24]);
                    9'd24: hdr_bad <= hdr_bad | (i_sd_data != HDR_ABYTES[7:0]);
                    9'd25: hdr_bad <= hdr_bad | (i_sd_data != HDR_ABYTES[15:8]);
                    9'd26: hdr_bad <= hdr_bad | (i_sd_data != HDR_ABYTES[23:16]);
                    9'd27: hdr_bad <= hdr_bad | (i_sd_data != HDR_ABYTES[31:24]);
                    9'd28: hdr_bad <= hdr_bad | (i_sd_data != HDR_ARATE[7:0]);
                    9'd29: hdr_bad <= hdr_bad | (i_sd_data != HDR_ARATE[15:8]);
                    9'd30: hdr_bad <= hdr_bad | (i_sd_data != 8'd2);       // ach = 2
                    9'd31: hdr_bad <= hdr_bad | (i_sd_data != 8'd0);
                    9'd32: hdr_bad <= hdr_bad | (i_sd_data != HDR_BS[7:0]);
                    9'd33: hdr_bad <= hdr_bad | (i_sd_data != HDR_BS[15:8]);
                    9'd34: hdr_bad <= hdr_bad | (i_sd_data != HDR_AMOD[7:0]);
                    9'd35: hdr_bad <= hdr_bad | (i_sd_data != HDR_AMOD[15:8]);
                    9'd40: h_nruns[7:0]  <= i_sd_data;
                    9'd41: h_nruns[15:8] <= i_sd_data;
                    // 段表：nsec 必须 ≥1；run0 还要扣掉头扇区
                    9'd51: begin
                        hdr_bad <= hdr_bad | (h_val < 32'd2);
                        rt_len0 <= sat20(h_val) - 20'd1;
                    end
                    9'd55: rt_rp0 <= h_val + 32'd1;
                    9'd63: begin
                        hdr_bad <= hdr_bad | (h_val == 32'd0);
                        rt_len1 <= sat20(h_val);
                    end
                    9'd67: rt_rp1 <= h_val;
                    9'd75: begin
                        hdr_bad <= hdr_bad | (h_val == 32'd0);
                        rt_len2 <= sat20(h_val);
                    end
                    9'd79: rt_rp2 <= h_val;
                    9'd87: begin
                        hdr_bad <= hdr_bad | (h_val == 32'd0);
                        rt_len3 <= sat20(h_val);
                    end
                    9'd91: rt_rp3 <= h_val;
                    default: ;
                endcase
            end
            if (st == S_HDR_CHK) begin
                hdr_done      <= 1'b1;
                rt_ok         <= hdr_ok;
                rt_last_frame <= h_frames[15:0] - 16'd1;
            end
        end
    end

endmodule
