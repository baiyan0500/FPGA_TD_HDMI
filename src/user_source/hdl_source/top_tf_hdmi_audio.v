
module top(
    input                       clk,
    input                       k1,             // 转场模式选择
    input                       k2,             // 切图（下一张）
    input                       k3,             // 对比度调节
    input                       k4,             // 亮度调节
    input  [3:0]                sw,             // SW1~SW4 拨码开关：功能层选择
    input                       uart_rxd,       // UART 接收（上位机）

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire [23:0] bc_rgb;
wire [23:0] trans_rgb;
wire        fade_req;
wire        fade_swap;
wire [1:0]  ctrl_mode;
wire [2:0]  ctrl_bright;
wire [2:0]  ctrl_contrast;
wire        ctrl_auto_play;
wire        ctrl_audio_viz;
wire        ctrl_audio_pause;
wire        ctrl_spectrum_en;
wire [7:0]  audio_level;
wire [47:0] spec_level;

// WAV 播放链
wire        wav_active;
wire [32:0] wav_rate_step;
wire        wav_stereo;
wire        wav_fifo_rd_en;
wire [15:0] wav_fifo_rd_data;
wire        wav_fifo_empty;
wire        wav_src_valid;
wire signed [23:0] wav_src_l, wav_src_r;
wire        uart_rx_done;
wire [7:0]  uart_rx_data;
wire [255:0] slogan_data;
wire [5:0]  slogan_len;
wire        slogan_dir;
wire        slogan_update;
wire        slogan_scroll;
wire        osd_vs;
wire        osd_de;
wire [23:0] osd_rgb;
wire        display_valid;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;
wire [23:0] shown_bcd;
wire [6:0]  seg_d0, seg_d1, seg_d2, seg_d3, seg_d4, seg_d5;

wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        audio_i2s_tgl;            // audio_mclk 域帧 toggle
wire [23:0] audio_left_mclk;         // audio_mclk 域帧样本（整帧稳定）
wire [23:0] audio_right_mclk;
reg         audio_valid;             // video_clk 域（toggle 同步后）
reg  [23:0] audio_left_data;
reg  [23:0] audio_right_data;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// ===================== 上电防抖复位（POR） =====================
// 移植自 lab_ex4_tf。原工程只有 sys/video 两个 PLL，本工程另有 audio PLL，
// 故扩展为等待全部三个 PLL 锁定后再计时——音频链路必须等 audio_mclk 稳定才可运行。
// 释放后锁存，忽略后续 PLL 抖动，避免运行中随机复位。
wire sys_pll_lock;
wire video_pll_lock;
wire rst_all;

reg [19:0] rst_cnt = 20'd0;
reg rst_all_reg = 1'b1;

always @(posedge clk) begin
    if (!rst_all_reg) begin
        // 一旦复位释放，忽略后续微小的 PLL 抖动，防止系统在使用时随机复位
        rst_all_reg <= 1'b0;
    end else if (sys_pll_lock && video_pll_lock && audio_pll_lock) begin
        // 等待 PLL 连续稳定 20ms @ 50MHz
        if (rst_cnt < 20'd1_000_000) begin
            rst_cnt <= rst_cnt + 1'b1;
            rst_all_reg <= 1'b1;
        end else begin
            rst_all_reg <= 1'b0;
        end
    end else begin
        rst_cnt <= 20'd0;
        rst_all_reg <= 1'b1;
    end
end

assign rst_all = rst_all_reg;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0),
    .extlock    (sys_pll_lock)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0),
    .extlock    (video_pll_lock)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_all) begin
    if (rst_all)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF 多图扫描与缓存（双缓冲） =====================
sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd6)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (k2),
    .key_auto          (ctrl_auto_play),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .fade_swap         (fade_swap),
    .fade_req          (fade_req),
    .shown_bcd         (shown_bcd),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .SD_nCS            (sd_ncs),
    .SD_DCLK           (sd_dclk),
    .SD_MOSI           (sd_mosi),
    .SD_MISO           (sd_miso),

    .wav_pause         (ctrl_audio_pause),
    .wav_active        (wav_active),
    .wav_rate_step     (wav_rate_step),
    .wav_stereo        (wav_stereo),
    .wav_rd_clk        (audio_mclk),
    .wav_fifo_rd_en    (wav_fifo_rd_en),
    .wav_fifo_rd_data  (wav_fifo_rd_data),
    .wav_fifo_empty    (wav_fifo_empty)
);

// 原始逻辑：数码管显示 SD 状态码 state_code（默认）
seg_decoder seg_decoder_state(.bin_data(state_code), .seg_data(seg_data_0));

// 播放计数 shown_bcd 的 6 位 7 段（SW2 拉高时显示）
seg_decoder seg_decoder_d0(.bin_data(shown_bcd[3:0]),   .seg_data(seg_d0));
seg_decoder seg_decoder_d1(.bin_data(shown_bcd[7:4]),   .seg_data(seg_d1));
seg_decoder seg_decoder_d2(.bin_data(shown_bcd[11:8]),  .seg_data(seg_d2));
seg_decoder seg_decoder_d3(.bin_data(shown_bcd[15:12]), .seg_data(seg_d3));
seg_decoder seg_decoder_d4(.bin_data(shown_bcd[19:16]), .seg_data(seg_d4));
seg_decoder seg_decoder_d5(.bin_data(shown_bcd[23:20]), .seg_data(seg_d5));

// 显示选择：SW2 拉高 = 播放计数；否则 = 原始 state_code（第 6 位显示，其余灭）
wire [6:0] disp0 = sw[1] ? seg_d0      : 7'b111_1111;
wire [6:0] disp1 = sw[1] ? seg_d1      : 7'b111_1111;
wire [6:0] disp2 = sw[1] ? seg_d2      : 7'b111_1111;
wire [6:0] disp3 = sw[1] ? seg_d3      : 7'b111_1111;
wire [6:0] disp4 = sw[1] ? seg_d4      : 7'b111_1111;
wire [6:0] disp5 = sw[1] ? seg_d5      : seg_data_0;

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (~rst_all),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,disp0}),
    .seg_data_1        ({1'b1,disp1}),
    .seg_data_2        ({1'b1,disp2}),
    .seg_data_3        ({1'b1,disp3}),
    .seg_data_4        ({1'b1,disp4}),
    .seg_data_5        ({1'b1,disp5})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (rst_all),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
// display_valid 为 100MHz 域准静态电平（上电 0，首图提交后恒 1），2 级同步到 video_clk
reg display_valid_s1, display_valid_s2;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        display_valid_s1 <= 1'b0;
        display_valid_s2 <= 1'b0;
    end else begin
        display_valid_s1 <= display_valid;
        display_valid_s2 <= display_valid_s1;
    end
end
assign vout_data = display_valid_s2 ? vout_data_raw : 24'd0;

// ===================== UART 上位机标语接收 =====================
uart_rx #(
    .CLK_FREQ (50_000_000),
    .BAUD_RATE(115200)
) u_uart_rx(
    .clk     (clk),
    .rst_n   (~rst_all),
    .rx      (uart_rxd),
    .rx_done (uart_rx_done),
    .rx_data (uart_rx_data)
);

slogan_ctrl u_slogan_ctrl(
    .clk      (clk),
    .rst      (rst_all),
    .rx_done  (uart_rx_done),
    .rx_data  (uart_rx_data),
    .o_slogan (slogan_data),
    .o_len    (slogan_len),
    .o_dir    (slogan_dir),
    .o_update (slogan_update),
    .o_scroll_en (slogan_scroll)
);

// ===================== 按键/拨码控制（K1模式 K3对比度 K4亮度 SW层选择）=====================
ctrl u_ctrl(
    .i_clk      (video_clk),
    .i_rst      (rst_all),
    .i_k1       (k1),
    .i_k3       (k3),
    .i_k4       (k4),
    .i_sw       (sw),
    .o_mode     (ctrl_mode),
    .o_bright   (ctrl_bright),
    .o_contrast (ctrl_contrast),
    .o_auto_play(ctrl_auto_play),
    .o_audio_viz(ctrl_audio_viz),
    .o_audio_pause(ctrl_audio_pause),
    .o_spectrum_en(ctrl_spectrum_en)
);

// ===================== 音频幅度提取 + 峰值保持（video_clk 域，与 I2S 接收输出同域）=====================
reg [7:0]  audio_amp;
reg [7:0]  audio_peak;
reg [15:0] audio_peak_cnt;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        audio_amp <= 8'd0; audio_peak <= 8'd0; audio_peak_cnt <= 16'd0;
    end else begin
        audio_amp <= audio_left_data[23] ? (~audio_left_data[22:15] + 8'd1) : audio_left_data[22:15];
        if (audio_amp > audio_peak)
            audio_peak <= audio_amp;
        else if (audio_peak_cnt == 16'd0)
            audio_peak <= (audio_peak == 8'd0) ? 8'd0 : audio_peak - 8'd1;
        audio_peak_cnt <= audio_peak_cnt + 16'd1;
    end
end
assign audio_level = audio_peak;   // 已在 video_clk 域，原跨域同步链不再需要

// ===================== 亮度/对比度调节（按键 K3/K4）=====================
brightness_contrast u_brightness_contrast(
    .i_bright   (ctrl_bright),
    .i_contrast (ctrl_contrast),
    .i_rgb      (vout_data),
    .o_rgb      (bc_rgb)
);

// ===================== 图片切换转场（4 种模式）=====================
transition_ctrl u_transition_ctrl(
    .i_clk  (video_clk),
    .i_rst  (rst_all),
    .i_vs   (vs),
    .i_de   (de),
    .i_mode (ctrl_mode),
    .i_rgb  (bc_rgb),
    .i_req  (fade_req),
    .o_swap (fade_swap),
    .o_rgb  (trans_rgb)
);

// ===================== OSD 图层叠加（标题栏 + 时间戳 + 模式 + 亮度/对比度）=====================
osd_layer u_osd_layer(
    .i_clk      (video_clk),
    .i_rst      (rst_all),
    .i_hs       (hs),
    .i_vs       (vs),
    .i_de       (de),
    .i_rgb      (trans_rgb),
    .i_bright   (ctrl_bright),
    .i_contrast (ctrl_contrast),
    .i_mode     (ctrl_mode),
    .i_slogan       (slogan_data),
    .i_slogan_len   (slogan_len),
    .i_slogan_dir   (slogan_dir),
    .i_slogan_update(slogan_update),
    .i_slogan_scroll(slogan_scroll),
    .i_audio_viz(ctrl_audio_viz),
    .i_audio_level(audio_level),
    .i_spectrum_en(ctrl_spectrum_en),
    .i_spec_level(spec_level),
    .o_hs       (),
    .o_vs       (osd_vs),
    .o_de       (osd_de),
    .o_rgb      (osd_rgb)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .mem_clk           (ext_mem_clk),
    .rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (FRAME_PIXELS),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_all),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// ===================== 音频：WAV 音源（ASRC 到 48k）+ I2S 发射（WAV 优先，回退测试音） =====================
// WAV 样本重采样（audio_mclk 域，读 sd_card_bmp 内 sd_card_wav 的跨时钟 FIFO）
wav_i2s_source u_wav_i2s_source (
    .I_mclk       (audio_mclk),
    .I_rst        (rst_all),
    .fifo_rd_en   (wav_fifo_rd_en),
    .fifo_rd_data (wav_fifo_rd_data),
    .fifo_empty   (wav_fifo_empty),
    .i_active     (wav_active),
    .i_pause      (ctrl_audio_pause),
    .i_step       (wav_rate_step),
    .i_stereo     (wav_stereo),
    .o_valid      (wav_src_valid),
    .o_l          (wav_src_l),
    .o_r          (wav_src_r)
);

hdmi_audio_tone_i2s_64fs #(
    .PHASE_INC (32'd39370534),
    .AMP       (24'sd2000000)
) u_hdmi_audio_tone_i2s_64fs (
    .I_mclk      (audio_mclk),
    .I_rst       (rst_all),
    .I_wav_sel   (wav_active),
    .I_wav_valid (wav_src_valid),
    .I_wav_l     (wav_src_l),
    .I_wav_r     (wav_src_r),
    .I_pause     (ctrl_audio_pause),
    .O_i2s_BCLK  (audio_i2s_bclk),
    .O_i2s_LRCK  (audio_i2s_lrck),
    .O_i2s_DOUT  (audio_i2s_dout)
);

// I2S 接收器挂 audio_mclk（与 I2S 发生器同源，2×BCLK 整数倍同步采样），
// 输出经 toggle 同步跨到 video_clk 域（样本整帧稳定，边沿采样无亚稳风险）
I2S_receiver u_I2S_receiver(
    .I_clk              (audio_mclk),
    .I_rst              (rst_all),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_toggle     (audio_i2s_tgl),
    .O_audio_left_data  (audio_left_mclk),
    .O_audio_right_data (audio_right_mclk)
);

// audio_mclk → video_clk：帧 toggle 3 级同步 + 边沿锁存样本
reg [2:0] audio_tgl_sync;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all)
        audio_tgl_sync <= 3'b0;
    else
        audio_tgl_sync <= {audio_tgl_sync[1:0], audio_i2s_tgl};
end

always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        audio_valid      <= 1'b0;
        audio_left_data  <= 24'd0;
        audio_right_data <= 24'd0;
    end else begin
        audio_valid <= audio_tgl_sync[2] ^ audio_tgl_sync[1];
        if (audio_tgl_sync[2] ^ audio_tgl_sync[1]) begin
            // toggle 翻转已同步 3 拍（120ns > 2 个源时钟周期），样本早已稳定
            audio_left_data  <= audio_left_mclk;
            audio_right_data <= audio_right_mclk;
        end
    end
end

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// Goertzel 8 频段频谱分析（与 I2S_receiver 同域，供 OSD 频谱图）
audio_spectrum u_audio_spectrum (
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .i_audio_valid (audio_valid),
    .i_audio_left  (audio_left_data),
    .o_level       (spec_level)
);

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (rst_all),
    .I_vs          (osd_vs),
    .I_de          (osd_de),
    .I_rgb         (osd_rgb),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (rst_all),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
