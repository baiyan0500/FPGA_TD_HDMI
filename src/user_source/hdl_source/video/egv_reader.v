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

    // ---- SD 扇区读客户端 ----
    output reg         o_sd_read,
    output reg  [31:0] o_sd_addr,
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
    localparam [15:0] LAST_FRAME = `EGV_FRAMES - 1;

    reg [1:0]  st;
    reg [7:0]  sec_i;         // 0..BLOCK_SEC-1
    reg [3:0]  amod_cnt;      // 0..AUDIO_MOD-1
    reg        byte_ph;       // 0=高字节先（视频）/低字节先（音频）
    reg [7:0]  byte_hi;
    reg [12:0] aud_cnt;       // 本帧已送出的有效音频字节数
    reg [31:0] gsec;          // 全局扇区号（跨帧累加）
    reg [31:0] phys;          // 当前物理 LBA
    reg [22:0] ftmr;
    reg        first;
    reg        stop_req;
    reg        eof_stop;      // 已播完整个容器：停在最后一帧，等 K1 重新启动

    wire frame_last = (o_frame_no == LAST_FRAME);

    wire is_audio = (amod_cnt == AMOD_LAST);

    // ---- 段表换算：顺序递增，跨段时跳到下一段物理起点 ----
    wire [31:0] gsec_n = gsec + 32'd1;
    reg  [31:0] phys_n;
    always @(*) begin
        if (gsec_n == `EGV_RG1)      phys_n = `EGV_RP1;
        else if (gsec_n == `EGV_RG2) phys_n = `EGV_RP2;
        else if (gsec_n == `EGV_RG3) phys_n = `EGV_RP3;
        else                         phys_n = phys + 32'd1;
    end

    wire frame_start_now = (st == S_FWAIT) && i_play && !stop_req &&
                           (first || (ftmr >= FRAME_CYC));

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st           <= S_IDLE;
            o_sd_read    <= 1'b0;
            o_sd_addr    <= 32'd0;
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
            gsec         <= 32'd0;
            phys         <= `EGV_RP0;
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
                    gsec    <= 32'd0;
                    phys    <= `EGV_RP0;
                    sec_i   <= 8'd0;
                    aud_cnt <= 13'd0;
                    first   <= 1'b1;
                    o_frame_no <= 16'd0;
                    o_active<= 1'b1;
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
                    gsec    <= gsec_n;
                    phys    <= phys_n;
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
                        o_sd_addr<= phys_n;          // 读核下一拍锁存地址
                    end
                end
            end
            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
