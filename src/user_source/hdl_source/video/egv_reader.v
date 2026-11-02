// ============================================================================
// egv_reader — EGV1 视频容器裸扇区读取器（sd_card_clk 100MHz 域）
//
// 按 24fps 节拍，每帧读入 BLOCK_SEC(201) 个扇区：
//   · 扇区号 i 满足 i % AUDIO_MOD == AUDIO_MOD-1 → 音频区（16 sector）
//   · 其余扇区 → 视频区 RGB565 大端（185 sector = 320*148 像素）
//
// 段表来源（优先级从高到低）：
//   1. 运行时解析：bmp_read 扫描按 "EGV1" 魔数找到容器起始 LBA 后，
//      本模块在首次播放前读一次容器头，动态装载段表/帧数（最多 4 段）。
//      容器在卡上搬动/重新封装后无需重新综合。
//   2. 文件被搬动（头部段表物理地址与发现位置不符）：按"整文件连续"回退，
//      用帧数×每帧扇区数推出长度。多数拷贝工具会为大文件分配连续空间。
//   3. 编译期常量（egv_cfg.vh）：仅当扫描窗口内没找到 EGV 且编译期 LBA 处
//      仍能读到 EGV1 头（同一文件未搬动）时使用。
//   4. 以上都不成立 → 拒播（黑屏），绝不拿过期段表去读别的扇区（花屏根源）。
//
// 段表校验：
//   · 魔数/版本/分辨率/fps/块几何/音频参数
//   · 1 ≤ n_runs ≤ 8，且逐段 nsec ≥ 1（run0 还要扣掉头扇区）
//   · 各段扇区之和 == frames × block_sectors（文件长度一致）
//   · run0 物理 LBA == 发现 LBA + 1（识别"整个文件被拷到别处"）
//   旧版无条件校验 run3 的 nsec，3 段容器的第 4 段槽位是 0 → 头被判坏 →
//   永远回退过期常量段表，是 SW3 花屏的直接原因。
//
// 节拍：一帧 = FRAME_CYC 拍（100MHz/24fps）。201 扇区 / 25MHz SPI 的纯传输
// 时间就是 32.9ms，余下 8.6ms 是命令开销与帧间空隙的预算。因此**每帧只用一条
// CMD18 读完整批**（跨段时才分成两条）：201 条独立 CMD17 光是每扇区 100~300us
// 的 tAC 就要 20~60ms，装不进帧预算，表现为视频卡顿 + 音频 FIFO 持续欠载。
// 音频按整帧预存进 FIFO，播放端与显示端因此天然对齐（见 video/egv_audio_fifo.v）。
// ============================================================================
`timescale 1ns/1ps
`include "egv_cfg.vh"

module egv_reader #(
    parameter [22:0]  FRAME_CYC = 23'd4_166_667,   // 100MHz / 24fps
    parameter integer AUD_BYTES = `EGV_AUDIO_BYTES,
    parameter integer BLOCK_SEC = `EGV_BLOCK_SECTORS,
    // 1 = 播完整个容器后自动回卷继续播（演示更连贯，避免画面停在末帧被误认为卡死）
    // 0 = 停在最后一帧等 K1 重新起播（原行为）
    parameter integer LOOP_PLAY = 1
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
                     S_HDR_CHK = 3'd2,   // 锁存模式判断
                     S_HDR_CHK2= 3'd5,   // 按已寄存的 mode 装载段表
                     S_FWAIT   = 3'd3,
                     S_SEC     = 3'd4;

    localparam [1:0] M_CONST  = 2'd0,    // 编译期常量段表
                     M_RT     = 2'd1,    // 运行时头部段表
                     M_CONTIG = 2'd2,    // 文件已搬动：按整文件连续回退
                     M_NONE   = 2'd3;    // 无可靠段表：拒播

    localparam [7:0]  LAST_SEC   = BLOCK_SEC - 1;
    localparam [3:0]  AMOD_LAST  = `EGV_AUDIO_MOD - 1;
    localparam [12:0] AUD_BYTES_V = AUD_BYTES;
    localparam [15:0] BLOCK_SEC_V = BLOCK_SEC;

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
    reg [2:0]  run_i;         // 当前物理段号（0..3）
    reg [19:0] run_rem;       // 本段剩余扇区数（含下一个要读的扇区），饱和于 RUN_MAX

    // ---- 段表来源选择（S_HDR_CHK 锁存）----
    reg [1:0]  mode_sel;
    reg [31:0] hdr_lba;       // 本次解析的容器头所在 LBA

    // ---- 运行时容器头解析 ----
    reg [8:0]  h_idx;         // 头内字节偏移 0..511
    reg [31:0] h_word;        // 最近 4 字节（LE 装配）
    reg [31:0] h_frames;
    reg [15:0] h_nruns;
    reg        hdr_bad;
    reg        hdr_done;      // 已尝试解析（成功/失败都置位，避免每次播放重读）
    reg        mg0, mg1, mg2, mg3;   // 魔数逐字节命中
    // 段表 4 段：实卡容器 nruns=3；8 段版本的 8:1 段表 mux（52bit 宽）
    // 是 SWNS 主要受害者（面积 +400 LUT、run_i→rt_rp 8 级组合链）。
    // 封装工具 MAX_RUNS 同步收紧到 4；超过 4 段的容器按连续回退/拒播处理
    reg [19:0] rt_len [0:3];
    reg [31:0] rt_rp  [0:3];
    reg [15:0] rt_last_frame;
    reg [23:0] rt_sum;
    reg [23:0] expect_secs;                                    // 最多 65536*201

    // 段长必须精确：中间段可达数十万扇区（本容器 run1 = 385024），
    // 16bit 饱和会让"段结束"提前触发 → 中途误跳到下一段，读到错位的数据流。
    // 20bit 上限 1048575 扇区（512MB），足够覆盖任意单段；批大小仍只需与 201 比较。
    localparam [19:0] RUN_MAX  = 20'hFFFFF;
    localparam [31:0] RUN0_SPAN = `EGV_RG1 - `EGV_RG0;
    localparam [31:0] RUN1_SPAN = `EGV_RG2 - `EGV_RG1;
    localparam [31:0] RUN2_SPAN = `EGV_RG3 - `EGV_RG2;
    localparam [19:0] RUN0_LEN = (RUN0_SPAN > 32'd1048575) ? RUN_MAX : RUN0_SPAN[19:0];
    localparam [19:0] RUN1_LEN = (RUN1_SPAN > 32'd1048575) ? RUN_MAX : RUN1_SPAN[19:0];
    localparam [19:0] RUN2_LEN = (RUN2_SPAN > 32'd1048575) ? RUN_MAX : RUN2_SPAN[19:0];

    function [19:0] sat20;
        input [31:0] v;
        begin
            sat20 = (|v[31:20]) ? RUN_MAX : v[19:0];
        end
    endfunction

    // 整文件连续回退的段长：frames × block_sectors
    //（段表 run0 已扣掉头扇区，这里同样只算数据扇区）
    // expect_secs 在解析头时已寄存，这里只做饱和截断，避免乘法进关键路径
    wire [19:0] contig_len  = (|expect_secs[23:20]) ? RUN_MAX : expect_secs[19:0];

    // ---- 活动段表的第 i 段（i 为"下一段"索引）----
    function [19:0] tbl_len;
        input [3:0] i;
        begin
            if (i >= 4'd4)
                tbl_len = RUN_MAX;
            else if (mode_sel == M_RT)
                tbl_len = rt_len[i[1:0]];
            else if (mode_sel == M_CONTIG)
                tbl_len = RUN_MAX;                      // 单段，不会跨段
            else
                tbl_len = (i == 4'd0) ? RUN0_LEN :
                          (i == 4'd1) ? RUN1_LEN :
                          (i == 4'd2) ? RUN2_LEN : RUN_MAX;
        end
    endfunction

    function [31:0] tbl_rp;
        input [3:0] i;
        begin
            if (mode_sel == M_RT)
                tbl_rp = rt_rp[(i >= 4'd4) ? 2'd3 : i[1:0]];
            else if (mode_sel == M_CONTIG)
                tbl_rp = hdr_lba + 32'd1;
            else
                tbl_rp = (i == 4'd0) ? `EGV_RP0 :
                         (i == 4'd1) ? `EGV_RP1 :
                         (i == 4'd2) ? `EGV_RP2 : `EGV_RP3;
        end
    endfunction

    wire [19:0] start_rem  = (mode_sel == M_RT)     ? rt_len[0] :
                             (mode_sel == M_CONTIG) ? contig_len : RUN0_LEN;
    wire [31:0] start_phys = (mode_sel == M_RT)     ? rt_rp[0] :
                             (mode_sel == M_CONTIG) ? (hdr_lba + 32'd1) :
                                                      `EGV_RP0;

    // 运行时段表有效/连续回退时用头里的帧数，否则用编译期常量
    wire [15:0] last_frame_v = (mode_sel == M_CONST) ? `EGV_FRAMES - 16'd1
                                                     : rt_last_frame;
    wire        frame_last   = (o_frame_no == last_frame_v);

    wire is_audio = (amod_cnt == AMOD_LAST);

    // ---- 段表推进：逐扇区 +1，跨段时跳到下一段物理起点 ----
    // 20bit 计数器代替 gsec 的 32bit 减法，批大小组合逻辑由 13.4ns 降到 ~6ns。
    // 下一段的长度/起点在进入当前段时预算好存寄存器（nxt_len_q/nxt_rp_q）：
    // ① 跨段那拍不再做 段表 4:1 mux + 20bit 比较，静态路径只剩寄存器；
    // ② tbl_len/tbl_rp 读的是 rt_len/rt_rp 存储器，连续赋值里调用带存储器
    //    读的 function 时仿真器不会随存储器更新重算（run_len_next 会一直停在
    //    复位时的 M_CONST 值），放到 always 块里按拍取值才与综合一致。
    reg  [19:0] nxt_len_q;    // 下一段扇区数
    reg  [31:0] nxt_rp_q;     // 下一段物理起点
    wire [3:0]  run_nx       = {1'b0, run_i} + 4'd1;
    wire        run_xn       = (run_rem == 20'd1);
    wire [19:0] run_len_next = nxt_len_q;
    wire [31:0] rp_next      = nxt_rp_q;
    wire [31:0] phys_nx      = run_xn ? rp_next : (phys + 32'd1);
    wire [19:0] run_rem_n    = run_xn ? run_len_next : (run_rem - 20'd1);

    // ---- 头部校验 ----
    wire magic_ok  = mg0 && mg1 && mg2 && mg3;
    wire frames_ok = (h_frames != 32'd0) && (h_frames <= 32'd65_536);
    wire nruns_ok  = (h_nruns >= 16'd1) && (h_nruns <= 16'd4);
    // run0 物理起点必须等于"头所在 LBA + 1"（文件首扇区是容器头）：
    // 整个文件被拷到别处时头里仍是旧段表，靠这条识别
    wire phys0_ok  = (rt_rp[0] == (hdr_lba + 32'd1));

    // 各段扇区之和必须等于 frames × block_sectors（文件长度一致性）。
    // 求和与乘法都在扫描头的过程中寄存：rt_len 各段在 100MHz 下逐字节写入，
    // 若放在 S_HDR_CHK 组合求和，单条路径可达 29.7ns（TD gate -19.8ns）。
    wire        sum_ok      = (rt_sum == expect_secs);

    // 校验结果在 S_HDR 期间连续寄存，模式判断放到下一拍，
    // 把 32bit 比较/24bit 比较与后面的启动段表 mux 分开
    reg         sum_ok_q;
    reg         phys0_ok_q;
    wire fields_ok_q = !hdr_bad && frames_ok && nruns_ok && sum_ok_q;
    wire [1:0] mode_new_q =
        (fields_ok_q && phys0_ok_q) ? M_RT :
        (fields_ok_q && !phys0_ok_q) ? M_CONTIG :
        (magic_ok && (hdr_lba == `EGV_BASE_LBA)) ? M_CONST : M_NONE;

    // ---- 批大小：min(本段剩余, 本帧剩余) ----
    // CMD17 每扇区一次独立事务时，卡的单扇区访问延迟（tAC，常见 100~300us）会
    // 乘以 201 次，一帧光命令开销就 20~60ms，41.67ms 帧预算根本装不下
    // → 视频卡顿、音频 FIFO 持续欠载（"刺啦"声）、画面只出前几行。
    // 恢复 CMD18 流式读：一段内物理地址连续，一次命令读完本帧剩余扇区。
    // 跨段时必须结束本批（段与段之间不连续），所以批大小取
    // min(本段剩余, 本帧剩余)；正常帧（段剩余 ≫ 201）就是"一帧一条命令"。
    // 段剩余是 20bit（run1 有 385024 扇区），这里先与 16bit 帧剩余做窄比较再取值。
    // 位宽优化：帧剩余 ≤ 201（< 65536），所以段剩余只要高 4 位非零就一定更大，
    // 不必做 20bit 比较。留着 20bit 比较器在 100MHz 下是 10 级进位链
    // （实测 SWNS -403ps，TD 报 run_rem → o_sd_count 10.1ns）。
    function [15:0] batch_size;
        input [19:0] run_r;
        input [15:0] frame_r;
        begin
            if (|run_r[19:16] || (run_r[15:0] >= frame_r))
                batch_size = frame_r;
            else
                batch_size = run_r[15:0];
        end
    endfunction

    wire [15:0] frame_rem_after = {8'd0, LAST_SEC - sec_i};   // 本扇区之后本帧还剩几个

    // ---- 段边界批长预寄存 ----
    // 段最后一扇区的整个 512B 传输期间 run_rem 恒为 1，有 500+ 拍预算把
    // "下一段剩余 vs 本帧剩余" 算好寄存；read_end 那拍只把寄存器搬到
    // o_sd_count（原实现直接在 read_end 拍做 20bit 比较：run_rem_n 组合链
    // 10.1ns，TD 报 sd_card_clk SWNS -403ps）。
    reg [15:0] batch_nx_q;
    always @(posedge clk or posedge rst) begin
        if (rst)
            batch_nx_q <= 16'd1;
        else if (st == S_SEC && run_xn)
            batch_nx_q <= batch_size(run_len_next, frame_rem_after);
    end

    wire frame_start_now = (st == S_FWAIT) && i_play && !stop_req && i_fill_ready &&
                           (first || (ftmr >= FRAME_CYC));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st           <= S_IDLE;
            o_sd_read    <= 1'b0;
            o_sd_addr    <= 32'd0;
            o_sd_count   <= 16'd1;
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
            run_i        <= 3'd0;
            run_rem      <= RUN0_LEN;
            ftmr         <= 23'd0;
            first        <= 1'b1;
            stop_req     <= 1'b0;
            eof_stop     <= 1'b0;
            hdr_lba      <= `EGV_BASE_LBA;
            nxt_len_q    <= RUN0_LEN;
            nxt_rp_q     <= `EGV_RP0;
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
                    if (!hdr_done) begin
                        // 首次播放：读一次容器头，动态装载段表/帧数。
                        // 扫描没找到 EGV 时探一下编译期 LBA，确认旧文件是否还在原地。
                        hdr_lba    <= i_egv_found ? i_egv_lba : `EGV_BASE_LBA;
                        o_sd_read  <= 1'b1;
                        o_sd_addr  <= i_egv_found ? i_egv_lba : `EGV_BASE_LBA;
                        o_sd_count <= 16'd1;
                        st         <= S_HDR;
                    end else if (mode_sel != M_NONE) begin
                        phys    <= start_phys;
                        run_i   <= 3'd0;
                        run_rem <= start_rem;
                        nxt_len_q <= tbl_len(4'd1);
                        nxt_rp_q  <= tbl_rp(4'd1);
                        sec_i   <= 8'd0;
                        aud_cnt <= 13'd0;
                        first   <= 1'b1;
                        o_frame_no <= 16'd0;
                        o_active<= 1'b1;
                        // 容器头只读 1 个扇区；数据帧的批长在 S_FWAIT 起帧时设置
                        o_sd_count <= 16'd1;
                        st      <= S_FWAIT;
                    end
                    // mode_sel == M_NONE：没有可靠段表，保持黑屏，绝不读错误扇区
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
                // 模式判断在本拍寄存到 mode_sel（解析块），下一拍再装载
                o_sd_read <= 1'b0;
                st        <= S_HDR_CHK2;
            end
            // ------------------------------------------------------------
            S_HDR_CHK2: begin
                o_sd_read <= 1'b0;
                if (i_play && !stop_req && mode_sel != M_NONE) begin
                    phys    <= start_phys;
                    run_i   <= 3'd0;
                    run_rem <= start_rem;
                    nxt_len_q <= tbl_len(4'd1);
                    nxt_rp_q  <= tbl_rp(4'd1);
                    sec_i   <= 8'd0;
                    aud_cnt <= 13'd0;
                    first   <= 1'b1;
                    o_frame_no <= 16'd0;
                    o_active<= 1'b1;
                    // 容器头只读 1 个扇区；数据帧的批长在 S_FWAIT 起帧时设置
                    o_sd_count <= 16'd1;
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
                    // CMD18 流式读：本批 = min(本段剩余, 本帧全部 201 扇区)
                    o_sd_count   <= batch_size(run_rem, BLOCK_SEC_V);
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
                    run_i   <= run_xn ? (run_i + 3'd1) : run_i;
                    // 跨段：把"下一段"提前装成"当前段"，并预算再下一段
                    if (run_xn) begin
                        nxt_len_q <= tbl_len(run_nx + 4'd1);
                        nxt_rp_q  <= tbl_rp(run_nx + 4'd1);
                    end
                    byte_ph <= 1'b0;                 // 512B 偶数长度，保险对齐
                    if (sec_i == LAST_SEC) begin
                        o_sd_read  <= 1'b0;
                        o_frame_no <= o_frame_no + 16'd1;
                        if (frame_last) begin
                            if (LOOP_PLAY) begin
                                // 自动回卷：帧号与段指针复位，下一帧从头播。
                                // 不置 eof_stop，音频 FIFO 也不 flush，声画都连续。
                                o_frame_no <= 16'd0;
                                phys       <= start_phys;
                                run_i      <= 3'd0;
                                run_rem    <= start_rem;
                                nxt_len_q  <= tbl_len(4'd1);
                                nxt_rp_q   <= tbl_rp(4'd1);
                                st         <= S_FWAIT;
                            end else begin
                                // 停止取流，画面冻结在最后一帧
                                o_active <= 1'b0;
                                st       <= S_IDLE;
                                eof_stop <= 1'b1;
                            end
                        end else
                            st <= S_FWAIT;
                        if (!i_play)
                            stop_req <= 1'b1;
                    end else begin
                        sec_i    <= sec_i + 8'd1;
                        amod_cnt <= (amod_cnt == AMOD_LAST) ? 4'd0 : amod_cnt + 4'd1;
                        // 批内地址由 SD 核自己推进（流式读），只有段边界会让本批
                        // 提前结束；此时下一条命令的起点/批长必须在**本拍**给出
                        // （读核结束脉冲后第 2 拍就采样），所以批长靠整扇区期间
                        // 预寄存的 batch_nx_q，静态时序上只剩寄存器到寄存器。
                        if (run_xn) begin
                            o_sd_addr  <= phys_nx;
                            o_sd_count <= batch_nx_q;
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
    //   40..41 n_runs 44+12i 每段：logical(跳过) / nsec / phys
    // 段表最多 4 段；nsec 校验只对 i < n_runs 的段做（未用槽位为 0）
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
            mode_sel      <= M_CONST;
            rt_last_frame <= 16'd0;
            rt_sum        <= 24'd0;
            expect_secs   <= 24'd0;
            sum_ok_q      <= 1'b0;
            phys0_ok_q    <= 1'b0;
            mg0           <= 1'b0;
            mg1           <= 1'b0;
            mg2           <= 1'b0;
            mg3           <= 1'b0;
            rt_len[0]     <= 20'd0;
            rt_len[1]     <= 20'd0;
            rt_len[2]     <= 20'd0;
            rt_len[3]     <= 20'd0;
            rt_rp[0]      <= 32'd0;
            rt_rp[1]      <= 32'd0;
            rt_rp[2]      <= 32'd0;
            rt_rp[3]      <= 32'd0;
        end else begin
            if (st == S_IDLE) begin
                // 头读取起始：S_IDLE 期间清零解析游标（FSM 块不再驱动这些寄存器）
                h_idx   <= 9'd0;
                h_word  <= 32'd0;
                hdr_bad <= 1'b0;
                rt_sum  <= 24'd0;
                sum_ok_q <= 1'b0;
                phys0_ok_q <= 1'b0;
                mg0     <= 1'b0;
                mg1     <= 1'b0;
                mg2     <= 1'b0;
                mg3     <= 1'b0;
            end else if (hdr_byte_en) begin
                h_idx  <= h_idx + 9'd1;
                h_word <= {i_sd_data, h_word[31:8]};
                case (h_idx)
                    9'd0:  begin hdr_bad <= hdr_bad | (i_sd_data != "E"); mg0 <= (i_sd_data == "E"); end
                    9'd1:  begin hdr_bad <= hdr_bad | (i_sd_data != "G"); mg1 <= (i_sd_data == "G"); end
                    9'd2:  begin hdr_bad <= hdr_bad | (i_sd_data != "V"); mg2 <= (i_sd_data == "V"); end
                    9'd3:  begin hdr_bad <= hdr_bad | (i_sd_data != "1"); mg3 <= (i_sd_data == "1"); end
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
                    // 帧数在此拍已完整，先把期望扇区数寄存（201 = 帧长）
                    9'd16: expect_secs <= h_frames[23:0] * BLOCK_SEC_V;
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
                    // 段表：run0 的 nsec 含头扇区，必须 ≥2；其后已用段必须 ≥1
                    // 求和推迟一拍，用已寄存的 rt_len 做 24bit 加法，
                    // 避免"字节→sat20→段长→求和"在单拍内串成 12ns 链
                    9'd51: begin
                        hdr_bad <= hdr_bad | (h_val < 32'd2);
                        rt_len[0] <= sat20(h_val) - 20'd1;
                    end
                    9'd52: rt_sum <= rt_sum + {4'd0, rt_len[0]};
                    9'd55: rt_rp[0] <= h_val + 32'd1;
                    9'd63: begin
                        if (h_nruns >= 16'd2)
                            hdr_bad <= hdr_bad | (h_val == 32'd0);
                        rt_len[1] <= sat20(h_val);
                    end
                    9'd64: if (h_nruns >= 16'd2) rt_sum <= rt_sum + {4'd0, rt_len[1]};
                    9'd67: rt_rp[1] <= h_val;
                    9'd75: begin
                        if (h_nruns >= 16'd3)
                            hdr_bad <= hdr_bad | (h_val == 32'd0);
                        rt_len[2] <= sat20(h_val);
                    end
                    9'd76: if (h_nruns >= 16'd3) rt_sum <= rt_sum + {4'd0, rt_len[2]};
                    9'd79: rt_rp[2] <= h_val;
                    9'd87: begin
                        if (h_nruns >= 16'd4)
                            hdr_bad <= hdr_bad | (h_val == 32'd0);
                        rt_len[3] <= sat20(h_val);
                    end
                    9'd88: if (h_nruns >= 16'd4) rt_sum <= rt_sum + {4'd0, rt_len[3]};
                    9'd91: rt_rp[3] <= h_val;
                    // 5 段以上：段表不装载（nruns_ok 拦下，回退连续/拒播）
                    default: ;
                endcase
            end
            // S_HDR 期间逐拍寄存校验结果（此时 rt_len/帧数已稳定）
            if (st == S_HDR) begin
                sum_ok_q   <= sum_ok;
                phys0_ok_q <= phys0_ok;
            end
            if (st == S_HDR_CHK) begin
                hdr_done      <= 1'b1;
                mode_sel      <= mode_new_q;
                rt_last_frame <= h_frames[15:0] - 16'd1;
            end else if (!i_play) begin
                // 每次重新起播都重读头：换卡/重新封装后无需复位即可生效
                hdr_done <= 1'b0;
            end
        end
    end

endmodule
