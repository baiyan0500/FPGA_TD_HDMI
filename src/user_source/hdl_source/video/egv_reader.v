// ============================================================================
// egv_reader — EGV1 视频容器裸扇区读取器（sd_card_clk 100MHz 域）
//
// 按 24fps 节拍，每帧读入 BLOCK_SEC(201) 个扇区：
//   · 扇区号 i 满足 i % AUDIO_MOD == AUDIO_MOD-1 → 音频区（16 sector）
//   · 其余扇区 → 视频区 RGB565 大端（185 sector = 320*148 像素）
//
// 目的地址由 egv_cfg.vh 的段表换算：文件在 exFAT 上被拆成若干物理段，
// 每跨过一段边界就跳到下一段的物理起点（段内顺序递增）。
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

    localparam [1:0] S_IDLE  = 2'd0,
                     S_FWAIT = 2'd1,
                     S_SEC   = 2'd2;

    localparam [7:0]  LAST_SEC   = BLOCK_SEC - 1;
    localparam [3:0]  AMOD_LAST  = `EGV_AUDIO_MOD - 1;
    localparam [12:0] AUD_BYTES_V = AUD_BYTES;
    localparam [15:0] BLOCK_SEC_V = BLOCK_SEC;
    localparam [15:0] LAST_FRAME = `EGV_FRAMES - 1;

    reg [1:0]  st;
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
    reg [1:0]  run_i;         // 当前物理段号（0..2）
    reg [19:0] run_rem;       // 本段剩余扇区数（含下一个要读的扇区），饱和于 RUN_MAX

    // 段长必须精确：中间段可达数十万扇区（本容器 run1 = 385024），
    // 16bit 饱和会让"段结束"提前触发 → 中途误跳到 RP2，读到错位的数据流。
    // 20bit 上限 1048575 扇区（512MB），足够覆盖任意单段；批大小仍只需与 201 比较。
    localparam [19:0] RUN_MAX  = 20'hFFFFF;
    localparam [31:0] RUN0_SPAN = `EGV_RG1 - `EGV_RG0;
    localparam [31:0] RUN1_SPAN = `EGV_RG2 - `EGV_RG1;
    localparam [19:0] RUN0_LEN = (RUN0_SPAN > 32'd1048575) ? RUN_MAX : RUN0_SPAN[19:0];
    localparam [19:0] RUN1_LEN = (RUN1_SPAN > 32'd1048575) ? RUN_MAX : RUN1_SPAN[19:0];

    wire frame_last = (o_frame_no == LAST_FRAME);

    wire is_audio = (amod_cnt == AMOD_LAST);

    // ---- 段表推进：逐扇区 +1，跨段时跳到下一段物理起点 ----
    // 20bit 计数器代替 gsec 的 32bit 减法，批大小组合逻辑由 13.4ns 降到 ~6ns
    wire        run_xn       = (run_rem == 20'd1);
    wire [19:0] run_len_next = (run_i == 2'd0) ? RUN1_LEN : RUN_MAX;
    wire [19:0] run_rem_n    = run_xn ? run_len_next : (run_rem - 20'd1);
    wire [31:0] rp_next      = (run_i == 2'd0) ? `EGV_RP1 :
                               (run_i == 2'd1) ? `EGV_RP2 : `EGV_RP3;
    wire [31:0] phys_nx      = run_xn ? rp_next : (phys + 32'd1);

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
                if (i_play && !stop_req && !eof_stop && i_sd_ready) begin
                    phys    <= `EGV_RP0;
                    run_i   <= 2'd0;
                    run_rem <= RUN0_LEN;
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

endmodule
