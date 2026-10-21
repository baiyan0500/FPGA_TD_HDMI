
module hdmi_audio_tone_i2s_64fs #(
    parameter [31:0] PHASE_INC = 32'd39370534,   // 兼容旧顶层，实际本版内部不用它
    parameter signed [23:0] AMP = 24'sd2000000,
    parameter integer NOTE_HOLD_FRAMES = 24000   // 每个音持续 0.5s @ 48kHz
)(
    input  wire I_mclk,      // 12.288MHz
    input  wire I_rst,
    // WAV 音源（同为 audio_mclk 域；I_wav_sel 为 100MHz 域电平，内部 2 级同步）
    input  wire I_wav_sel,       // 1=WAV 音源，0=系统测试音
    input  wire I_wav_valid,     // WAV 帧样本有效（0=静音槽）
    input  wire signed [23:0] I_wav_l,
    input  wire signed [23:0] I_wav_r,
    input  wire I_pause,         // 音频暂停（层3 K1；对测试音与 WAV 均生效）
    output reg  O_i2s_BCLK,
    output reg  O_i2s_LRCK,
    output reg  O_i2s_DOUT
);

// do/re/mi/fa/so/la/si/do  （C4 D4 E4 F4 G4 A4 B4 C5）
// 相位增量按 48kHz 采样率计算
function [31:0] note_inc_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: note_inc_lut = 32'd23409862; // do  C4 261.63Hz
            3'd1: note_inc_lut = 32'd26276681; // re  D4 293.66Hz
            3'd2: note_inc_lut = 32'd29494578; // mi  E4 329.63Hz
            3'd3: note_inc_lut = 32'd31248410; // fa  F4 349.23Hz
            3'd4: note_inc_lut = 32'd35075155; // so  G4 392.00Hz
            3'd5: note_inc_lut = 32'd39370534; // la  A4 440.00Hz
            3'd6: note_inc_lut = 32'd44191930; // si  B4 493.88Hz
            default: note_inc_lut = 32'd46819716; // do  C5 523.25Hz
        endcase
    end
endfunction

reg  [5:0]  S_bit_cnt;
reg  [63:0] S_shift_reg;
reg  [31:0] S_phase_acc;
reg signed [23:0] S_sample_word;    // 左声道槽
reg signed [23:0] S_sample_word_r;  // 右声道槽
reg signed [23:0] S_sample_next;
reg  [2:0]  S_note_idx;
reg [15:0]  S_note_frame_cnt;

// WAV 选择电平同步（100MHz → 12.288MHz，慢电平 2 级足够）
reg wav_sel_s1, wav_sel_s2;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        wav_sel_s1 <= 1'b0;
        wav_sel_s2 <= 1'b0;
    end else begin
        wav_sel_s1 <= I_wav_sel;
        wav_sel_s2 <= wav_sel_s1;
    end
end

// 暂停电平同步（video_clk 域 → 12.288MHz）
reg pau_s1, pau_s2;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        pau_s1 <= 1'b0;
        pau_s2 <= 1'b0;
    end else begin
        pau_s1 <= I_pause;
        pau_s2 <= pau_s1;
    end
end

wire [31:0] W_note_inc = note_inc_lut(S_note_idx);

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        O_i2s_BCLK      <= 1'b0;
        O_i2s_LRCK      <= 1'b0;
        O_i2s_DOUT      <= 1'b0;
        S_bit_cnt       <= 6'd0;
        S_shift_reg     <= 64'd0;
        S_phase_acc     <= 32'd0;
        S_sample_word   <= 24'sd0;
        S_sample_word_r <= 24'sd0;
        S_sample_next   <= AMP;
        S_note_idx      <= 3'd0;
        S_note_frame_cnt<= 16'd0;
    end
    else begin
        // 保持和你现有接收端兼容的 64fs 发送时序
        O_i2s_BCLK <= ~O_i2s_BCLK;

        if (O_i2s_BCLK == 1'b1) begin
            O_i2s_DOUT  <= S_shift_reg[63];
            S_shift_reg <= {S_shift_reg[62:0], 1'b0};

            if (S_bit_cnt == 6'd63) begin
                S_bit_cnt <= 6'd0;

                if (O_i2s_LRCK == 1'b0) begin
                    // 左声道发完 → 右声道用独立样本
                    O_i2s_LRCK  <= 1'b1;
                    S_shift_reg <= {S_sample_word_r[23:0], 40'd0};
                end
                else begin
                    // 右声道发完 → 装载下一帧左声道样本并选择音源
                    O_i2s_LRCK <= 1'b0;

                    if (wav_sel_s2) begin
                        // WAV 音源：无效或暂停时静音（暂停时 wav_i2s_source 已冻结输出）
                        S_sample_word   <= (I_wav_valid && !pau_s2) ? I_wav_l : 24'sd0;
                        S_sample_word_r <= (I_wav_valid && !pau_s2) ? I_wav_r : 24'sd0;
                        S_shift_reg     <= {((I_wav_valid && !pau_s2) ? I_wav_l : 24'sd0), 40'd0};
                    end
                    else if (pau_s2) begin
                        // 测试音暂停：静音并冻结音阶进度
                        S_sample_word   <= 24'sd0;
                        S_sample_word_r <= 24'sd0;
                        S_shift_reg     <= 64'd0;
                    end
                    else begin
                        // 系统测试音：方波音阶
                        S_phase_acc <= S_phase_acc + W_note_inc;
                        if (S_phase_acc[31])
                            S_sample_next <= AMP;
                        else
                            S_sample_next <= -AMP;

                        S_sample_word   <= S_sample_next;
                        S_sample_word_r <= S_sample_next;
                        S_shift_reg     <= {S_sample_next[23:0], 40'd0};

                        if (S_note_frame_cnt == NOTE_HOLD_FRAMES - 1) begin
                            S_note_frame_cnt <= 16'd0;
                            if (S_note_idx == 3'd7)
                                S_note_idx <= 3'd0;
                            else
                                S_note_idx <= S_note_idx + 3'd1;
                        end
                        else begin
                            S_note_frame_cnt <= S_note_frame_cnt + 16'd1;
                        end
                    end
                end
            end
            else begin
                S_bit_cnt <= S_bit_cnt + 6'd1;
            end
        end
    end
end

endmodule
