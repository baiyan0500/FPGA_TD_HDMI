// ============================================================================
// wav_i2s_source — WAV 音频源（12.288MHz 域）
//
// 从 sd_card_wav 的跨时钟 FIFO 读取 16bit PCM 样本流，经分数重采样
// （ASRC，线性插值）转换到 48kHz 帧率，输出 24bit 左右声道帧样本，
// 供 hdmi_audio_tone_i2s_64fs 在 WAV 模式下发送。
//
// ASRC：acc 为 1.32 定点相位（33bit，bit32 为进位）；每输出帧 acc += step，
//       step = fs_wav × 2^32 / 48000（sd_card_wav 查表产生，active 前已稳定）。
//       进位时消费一个输入帧（mono=1 字 / stereo=2 字），输出样本位于
//       prev/curr 两输入帧之间按 acc 小数部分线性插值。
//
// 暂停：acc/prev/curr/FIFO 全部冻结，o_valid=0（tone 发送静音）。
// ============================================================================
module wav_i2s_source (
    input  wire        I_mclk,        // 12.288MHz
    input  wire        I_rst,

    // FIFO 读端口（FWFT：!empty 时 rd_data 有效，rd_en 消费一个）
    output reg         fifo_rd_en,
    input  wire [15:0] fifo_rd_data,
    input  wire        fifo_empty,

    // 控制/参数（100MHz 域输入，模块内 2 级同步；step/stereo 在 active 前已稳定）
    input  wire        i_active,
    input  wire        i_pause,
    input  wire [32:0] i_step,
    input  wire        i_stereo,

    // 帧样本输出（整个帧周期保持稳定，tone 在帧边界采样）
    output reg         o_valid,
    output reg signed [23:0] o_l,
    output reg signed [23:0] o_r
);

// ---------------------------------------------------------------------------
// 跨域同步（active/pause 电平 2 级；step/stereo 多比特但保证 active 前稳定）
// ---------------------------------------------------------------------------
reg       act_s1, act_s2;
reg       pau_s1, pau_s2;
reg [32:0] step_s1, step_s2;
reg       ste_s1, ste_s2;

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        act_s1 <= 1'b0; act_s2 <= 1'b0;
        pau_s1 <= 1'b0; pau_s2 <= 1'b0;
        step_s1 <= 33'd0; step_s2 <= 33'd0;
        ste_s1 <= 1'b0;  ste_s2 <= 1'b0;
    end else begin
        act_s1 <= i_active;  act_s2 <= act_s1;
        pau_s1 <= i_pause;   pau_s2 <= pau_s1;
        step_s1 <= i_step;   step_s2 <= step_s1;
        ste_s1 <= i_stereo;  ste_s2 <= ste_s1;
    end
end

// ---------------------------------------------------------------------------
// 帧相位（256 拍 @12.288MHz = 48kHz 帧节拍）
// ---------------------------------------------------------------------------
reg [7:0] fphase;
always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst)
        fphase <= 8'd0;
    else
        fphase <= fphase + 8'd1;
end

// ---------------------------------------------------------------------------
// 帧 pop 流水 + ASRC 主状态声明
//   读侧队列是 FWFT，但 fifo_rd_en 是寄存器输出：拉高后 FIFO 要在下一个
//   时钟沿才弹出队首。因此数据必须在"发出 rd_en 的下一拍"采样，同拍采到
//   的仍是当前队首；连续两拍各采一次就会把同一个字读两遍（立体声 R 声道
//   重复 L 字、下一字被弹出后丢弃 = 声道错位/咔哒声）。
// ---------------------------------------------------------------------------
localparam PP_IDLE = 2'd0,   // 空闲
           PP_CAP  = 2'd1,   // L 字有效（rd_en 后一拍）
           PP_RDR  = 2'd2,   // 立体声：发 R 字 rd_en
           PP_CAPR = 2'd3;   // 立体声：R 字有效

reg [1:0]  pp;
reg signed [15:0] pop_l, pop_r;
reg        pp_done;    // pop 完成脉冲（pop_l/pop_r 已锁存）

// ---------------------------------------------------------------------------
// ASRC 主状态
// ---------------------------------------------------------------------------
localparam AS_WAIT = 2'd0,   // 等 active + FIFO 数据，预填 prev
           AS_P1   = 2'd1,   // 预填 curr
           AS_RUN  = 2'd3;   // 正常重采样输出

reg [2:0] as;
reg [32:0] acc;
reg signed [15:0] prev_l, prev_r, curr_l, curr_r;
reg pend_carry;              // carry pop 进行中（pp_done 时更新输出）

wire frame_tick = (fphase == 8'd255) && (as == AS_RUN);
wire [32:0] acc_sum = acc + step_s2;
wire carry = acc_sum[32];

// pop 启动条件（AS_WAIT 预填 / AS_P1 预填 / AS_RUN 进位）
//   pp_done 未消费前不再发起：单声道一拍即可完成 pop，若下一拍立刻再 pop，
//   会多消费一个字且该字在 AS_RUN 下被丢弃（旧逻辑隔字丢音的另一来源）
wire pop_start = (pp == PP_IDLE) && !pp_done && !pend_carry && !fifo_empty && (
                 (as == AS_WAIT && act_s2 && !pau_s2) ||
                 (as == AS_P1) ||
                 (frame_tick && carry && !pau_s2));

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        pp <= PP_IDLE;
        fifo_rd_en <= 1'b0;
        pop_l <= 16'sd0;
        pop_r <= 16'sd0;
        pp_done <= 1'b0;
    end else begin
        pp_done <= 1'b0;
        fifo_rd_en <= 1'b0;
        case (pp)
            PP_IDLE: begin
                if (pop_start) begin
                    fifo_rd_en <= 1'b1;          // FIFO 下一拍弹出该字
                    pp <= PP_CAP;
                end
            end
            PP_CAP: begin
                pop_l <= fifo_rd_data;           // rd_en 后一拍数据才有效
                if (!ste_s2) begin
                    pop_r <= fifo_rd_data;       // mono：L=R
                    pp_done <= 1'b1;
                    pp <= PP_IDLE;
                end else begin
                    pp <= PP_RDR;
                end
            end
            PP_RDR: begin
                // R 字可能还没搬进输出队列（跨时钟取数流水），等非空再取
                if (!fifo_empty) begin
                    fifo_rd_en <= 1'b1;
                    pp <= PP_CAPR;
                end
            end
            PP_CAPR: begin
                pop_r <= fifo_rd_data;
                pp_done <= 1'b1;
                pp <= PP_IDLE;
            end
            default: pp <= PP_IDLE;
        endcase
    end
end

// 线性插值（16bit 域，返回 24bit 左对齐）
function signed [23:0] lerp24;
    input signed [15:0] a;
    input signed [15:0] b;
    input [31:0] f;
    reg signed [16:0] d;
    reg signed [49:0] p;
    begin
        d = b - a;
        p = d * $signed({1'b0, f});
        lerp24 = {a + p[48:32], 8'd0};
    end
endfunction

always @(posedge I_mclk or posedge I_rst) begin
    if (I_rst) begin
        as <= AS_WAIT;
        acc <= 33'd0;
        prev_l <= 16'sd0; prev_r <= 16'sd0;
        curr_l <= 16'sd0; curr_r <= 16'sd0;
        pend_carry <= 1'b0;
        o_valid <= 1'b0;
        o_l <= 24'sd0;
        o_r <= 24'sd0;
    end else begin
        // ---- 帧节拍 ----
        // 只在没有在途 pop 时推进：立体声 pop 要等 R 字（最长数拍），
        // 期间若再执行 prev/curr 移位，插值基准会与 acc 相位错位
        if (frame_tick && !pau_s2 && (pp == PP_IDLE) && !pend_carry) begin
            if (carry) begin
                if (!fifo_empty) begin
                    acc <= acc_sum - 33'd4294967296;
                    prev_l <= curr_l;
                    prev_r <= curr_r;
                    pend_carry <= 1'b1;
                end
                // FIFO 欠载：相位与输出保持，恢复后下一拍再消费，
                // 避免 acc 空转导致恢复瞬间跳样本
            end else begin
                acc <= acc_sum;
                o_l <= lerp24(prev_l, curr_l, acc_sum[31:0]);
                o_r <= lerp24(prev_r, curr_r, acc_sum[31:0]);
                o_valid <= 1'b1;
            end
        end

        // ---- pop 完成事件 ----
        if (pp_done) begin
            if (as == AS_WAIT) begin
                prev_l <= pop_l;
                prev_r <= pop_r;
                as <= AS_P1;
            end else if (as == AS_P1) begin
                curr_l <= pop_l;
                curr_r <= pop_r;
                acc <= 33'd0;
                as <= AS_RUN;
                o_l <= {pop_l, 8'd0};
                o_r <= {pop_r, 8'd0};
                o_valid <= 1'b1;
            end else if (pend_carry) begin
                curr_l <= pop_l;
                curr_r <= pop_r;
                o_l <= lerp24(prev_l, pop_l, acc[31:0]);
                o_r <= lerp24(prev_r, pop_r, acc[31:0]);
                o_valid <= 1'b1;
                pend_carry <= 1'b0;
            end
        end

        // ---- 暂停：静音 + 相位冻结 ----
        if (as == AS_RUN && pau_s2)
            o_valid <= 1'b0;
    end
end

endmodule
