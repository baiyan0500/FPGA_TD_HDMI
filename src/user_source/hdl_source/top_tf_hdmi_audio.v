
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
parameter BUF2_ADDR     = 24'd614400;   // 视频双缓冲（层3）
parameter BUF3_ADDR     = 24'd921600;
// 148 行居中后上下各 92 行黑边，中间 296 行只在帧内局部重写
parameter VID_TOP_OFF   = 24'd58880;    // 92 * 640

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
wire [1:0]  ctrl_layer;
wire [1:0]  ctrl_mode;
wire [2:0]  ctrl_bright;
wire [2:0]  ctrl_contrast;
wire        ctrl_auto_play;
wire        ctrl_audio_pause;
wire        ctrl_next_img_en;
wire [1:0]  ctrl_viz_mode;
wire        ctrl_video_play;
wire        ctrl_danmaku_en;
wire        ctrl_spectrum_en;      // 层3 频谱开关
wire        ctrl_resmon_en;
wire [7:0]  audio_level;
wire [191:0] spec_level;

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
wire [4:0]  img_count;
wire [15:0] src_w_bcd;
wire [15:0] src_h_bcd;
wire        src_tgl;
wire        sd_ready;
wire        scan_done_sd;
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

// ---- 层3 视频链（sd_card_clk 100MHz 域）----
wire        vid_layer_v;        // 层3 选中（video_clk 域）
wire        vid_layer;          // 层3 选中（100MHz 域）
wire        vid_play_v;         // 用户播放开关（video_clk 域）
wire        vid_play_w;         // 100MHz 域
wire        vid_wr_own;         // 视频独占帧写口（含收尾）
wire        vid_load_busy;

wire        egv_sd_read;
wire [31:0] egv_sd_addr;
wire [15:0] egv_sd_count;
wire        egv_cli_dv;
wire [7:0]  egv_cli_data;
wire        egv_cli_end;

wire        egv_pix_en;
wire [15:0] egv_pix;
wire        egv_fstart;
wire        egv_aud_en;
wire [7:0]  egv_aud_byte;
wire        egv_afstart;
wire [15:0] egv_frame_no;

wire        vf_wr_req;
wire        vf_wr_ack;
wire        vf_wr_en;
wire [31:0] vf_wr_data;
wire [20:0] vf_wr_len;
wire        vf_wr_bank;
wire        vf_addr_full;
wire        vf_disp_bank;
wire        vf_ready;
wire        vf_frame_ready;
wire        vf_busy;
wire        vf_frame_end;
reg         vid_ftgl;

wire        wr_ack_all;
wire        wr_req_mux;
wire        wr_en_mux;
wire [31:0] wr_data_mux;
wire [20:0] wr_len_mux;
wire [1:0]  wr_idx_mux;
wire        wr_vflip_mux;
wire [23:0] wr_addr0_mux, wr_addr1_mux, wr_addr2_mux, wr_addr3_mux;

wire [23:0] rd_addr_idx_mux;

// ---- 视频音轨 FIFO ----
wire        vid_aud_on;         // 视频音轨有效（100MHz 域）
wire        vid_aud_on_m;       // audio_mclk 域
wire        vid_layer_m;        // 层3 选中（audio_mclk 域）
wire        vid_play_m;         // 播放开关（audio_mclk 域）
wire        vid_aud_arm_m;      // 首帧已落地（audio_mclk 域）
wire        aud_sel_m;          // 音频源选择（audio_mclk 域）
wire        egv_afifo_rden;
wire [15:0] egv_afifo_data;
wire        egv_afifo_empty;
wire        aud_rden;
wire [15:0] aud_data;
wire        aud_empty;
wire        aud_active;
wire [32:0] aud_step;
wire        aud_stereo;
wire        aud_pause;
wire        dm_tgl;             // 50MHz 域：新弹幕 toggle
wire [191:0] dm_text;
wire [4:0]  dm_len;
reg  [3:0]  dm_color_seed;
reg         dm_tgl_r;
wire        vid_on_v;           // 层3 且正在播放（video_clk 域）
wire        vid_show;           // 层3 选中且视频缓冲已就绪（video_clk 域）

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
    .SCAN_TARGET_COUNT (5'd16)
) sd_card_bmp_m0(
    .clk               (sd_card_clk),
    .rst               (rst_all),
    .key_next          (k2),
    .key_auto          (ctrl_auto_play),
    .i_next_en         (next_img_en_w),
    .state_code        (state_code),
    .img_count         (img_count),
    .sd_ready          (sd_ready),
    .scan_done_o       (scan_done_sd),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .fade_swap         (fade_swap),
    .fade_req          (fade_req),
    .shown_bcd         (shown_bcd),
    .o_src_w_bcd       (src_w_bcd),
    .o_src_h_bcd       (src_h_bcd),
    .o_src_tgl         (src_tgl),

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
    .wav_fifo_empty    (wav_fifo_empty),

    .i_video_play      (vid_wr_own),
    .i_egv_sd_read     (egv_sd_read),
    .i_egv_sd_addr     (egv_sd_addr),
    .i_egv_sd_count    (egv_sd_count),
    .o_cli_data_valid  (egv_cli_dv),
    .o_cli_data        (egv_cli_data),
    .o_cli_read_end    (egv_cli_end),
    .o_load_busy       (vid_load_busy)
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
assign vout_data = (display_valid_s2 | vid_show) ? vout_data_raw : 24'd0;

// 启动状态跨域：100MHz 准静态电平 → video_clk 2 级同步
reg        sd_ready_s1, sd_ready_s2;
reg        scan_done_s1, scan_done_s2;
reg [4:0]  img_count_s1, img_count_s2;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        sd_ready_s1  <= 1'b0;  sd_ready_s2  <= 1'b0;
        scan_done_s1 <= 1'b0;  scan_done_s2 <= 1'b0;
        img_count_s1 <= 5'd0;  img_count_s2 <= 5'd0;
    end else begin
        sd_ready_s1  <= sd_ready;
        sd_ready_s2  <= sd_ready_s1;
        scan_done_s1 <= scan_done_sd;
        scan_done_s2 <= scan_done_s1;
        img_count_s1 <= img_count;
        img_count_s2 <= img_count_s1;
    end
end

// 视频显示缓冲号 / 就绪标志跨域（100MHz → video_clk，准静态；读 FSM 在 vs 后锁存）
reg vf_disp_bank_s1, vf_disp_bank_s2;
reg vf_ready_s1, vf_ready_s2;
always @(posedge video_clk or posedge rst_all) begin
    if (rst_all) begin
        vf_disp_bank_s1 <= 1'b0;
        vf_disp_bank_s2 <= 1'b0;
        vf_ready_s1     <= 1'b0;
        vf_ready_s2     <= 1'b0;
    end else begin
        vf_disp_bank_s1 <= vf_disp_bank;
        vf_disp_bank_s2 <= vf_disp_bank_s1;
        vf_ready_s1     <= vf_ready;
        vf_ready_s2     <= vf_ready_s1;
    end
end
// 视频缓冲黑场初始化完成前只出黑屏，避免上电 SDRAM 随机内容闪一下
assign vid_show = vid_layer_v & vf_ready_s2;
assign rd_addr_idx_mux = vid_layer_v ? (24'd2 + vf_disp_bank_s2)
                                     : {22'd0, disp_buf_idx};
// 源尺寸 BCD 为 100MHz 域准静态总线，与 src_tgl 一同更新；
// osd_layer 内部用 2 级同步的 toggle 边沿锁存，无需在此再打拍

// ===================== 层3 视频链跨域（video_clk → sd_card_clk）=====================
reg [1:0] vid_layer_s;
reg [1:0] vid_play_s;
reg [1:0] next_img_s;

always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all) begin
        vid_layer_s <= 2'd0;
        vid_play_s  <= 2'd0;
        next_img_s  <= 2'd0;
    end else begin
        vid_layer_s <= {vid_layer_s[0], vid_layer_v};
        vid_play_s  <= {vid_play_s[0],  vid_play_v};
        next_img_s  <= {next_img_s[0],  ctrl_next_img_en};
    end
end

assign vid_layer     = vid_layer_s[1];
assign vid_play_w    = vid_play_s[1];
assign next_img_en_w = next_img_s[1];

wire egv_active;

// 视频独占帧写口：选定层3 且 BMP 装载已结束才接管；收尾由 vf_busy / egv_active 维持，
// 保证"半帧写口交接"不会发生（frame_fifo_write 无法中途改长度）
assign vid_wr_own = (vid_layer & ~vid_load_busy) | vf_busy | egv_active;

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

// ===================== 弹幕文本 =====================
// 复用上位机输入的 ASCII 标语：取前 24 个字符，按 danmaku_osd 的低字节优先顺序重排；
// 每条新消息翻转 toggle 并换一个起始色（同一条内逐字变色由 danmaku_osd 完成）
reg [191:0] dm_text_r;
integer dm_i;
always @(*) begin
    for (dm_i = 0; dm_i < 24; dm_i = dm_i + 1)
        dm_text_r[dm_i*8 +: 8] = slogan_data[(31-dm_i)*8 +: 8];
end
assign dm_text = dm_text_r;
assign dm_len  = (slogan_len > 6'd24) ? 5'd24 : slogan_len[4:0];
assign dm_tgl  = dm_tgl_r;

always @(posedge clk or posedge rst_all) begin
    if (rst_all) begin
        dm_tgl_r      <= 1'b0;
        dm_color_seed <= 4'd0;
    end else if (slogan_update) begin
        dm_tgl_r      <= ~dm_tgl_r;
        dm_color_seed <= dm_color_seed + 4'd1;
    end
end

// ===================== 按键/拨码控制（K1模式 K3对比度 K4亮度 SW层选择）=====================
ctrl u_ctrl(
    .i_clk      (video_clk),
    .i_rst      (rst_all),
    .i_k1       (k1),
    .i_k2       (k2),
    .i_k3       (k3),
    .i_k4       (k4),
    .i_sw       (sw),
    .o_layer    (ctrl_layer),
    .o_mode     (ctrl_mode),
    .o_bright   (ctrl_bright),
    .o_contrast (ctrl_contrast),
    .o_next_img_en(ctrl_next_img_en),
    .o_auto_play(ctrl_auto_play),
    .o_audio_pause(ctrl_audio_pause),
    .o_viz_mode (ctrl_viz_mode),
    .o_video_play(ctrl_video_play),
    .o_danmaku_en(ctrl_danmaku_en),
    .o_spectrum_en(ctrl_spectrum_en),
    .o_resmon_en(ctrl_resmon_en)
);

assign vid_layer_v = (ctrl_layer == 2'd3);
assign vid_play_v  = ctrl_video_play;
assign vid_on_v    = vid_layer_v & vid_play_v;

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
    .i_viz_mode     (ctrl_viz_mode),
    .i_spec_en      (ctrl_spectrum_en),
    .i_audio_level  (audio_level),
    .i_spec_level   (spec_level),
    .i_dm_en        (ctrl_danmaku_en),
    .i_dm_text      (dm_text),
    .i_dm_len       (dm_len),
    .i_dm_color     (dm_color_seed),
    .i_dm_tgl       (dm_tgl),
    .o_dm_ack       (),
    .i_rm_en        (ctrl_resmon_en),
    .i_video_on     (vid_on_v),
    .i_vid_ftgl     (vid_ftgl),
    .i_display_valid(display_valid_s2 | vid_show),
    .i_sd_init_done(sd_ready_s2),
    .i_scan_done(scan_done_s2),
    .i_img_count(img_count_s2),
    .i_src_w_bcd(src_w_bcd),
    .i_src_h_bcd(src_h_bcd),
    .i_src_tgl(src_tgl),
    .i_auto_play(ctrl_auto_play),
    .o_hs       (),
    .o_vs       (osd_vs),
    .o_de       (osd_de),
    .o_rgb      (osd_rgb)
);

// ---- 帧写口复用：BMP（翻转、整帧） / 视频（顺序、中间 296 行）----
assign wr_req_mux   = vid_wr_own ? vf_wr_req  : sd_card_write_req;
assign wr_en_mux    = vid_wr_own ? vf_wr_en   : sd_card_write_en;
assign wr_data_mux  = vid_wr_own ? vf_wr_data : sd_card_write_data;
assign wr_len_mux   = vid_wr_own ? vf_wr_len  : FRAME_PIXELS[20:0];
// 视频初始化整帧（基址 0）用 0/1 号；局部写用 2/3 号（基址带 92 行偏移）
assign wr_idx_mux   = vid_wr_own ? (vf_addr_full ? {1'b0, vf_wr_bank}
                                                 : {1'b1, vf_wr_bank})
                                 : write_buf_idx;
assign wr_vflip_mux = ~vid_wr_own;
assign wr_addr0_mux = vid_wr_own ? BUF2_ADDR : BUF0_ADDR;
assign wr_addr1_mux = vid_wr_own ? BUF3_ADDR : BUF1_ADDR;
assign wr_addr2_mux = BUF2_ADDR + VID_TOP_OFF;
assign wr_addr3_mux = BUF3_ADDR + VID_TOP_OFF;

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
    .read_addr_2       (BUF2_ADDR),
    .read_addr_3       (BUF3_ADDR),
    .read_addr_index   (rd_addr_idx_mux),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (wr_req_mux),
    .write_req_ack     (wr_ack_all),
    .write_finish      (frame_write_finish),
    .write_addr_0      (wr_addr0_mux),
    .write_addr_1      (wr_addr1_mux),
    .write_addr_2      (wr_addr2_mux),
    .write_addr_3      (wr_addr3_mux),
    .write_addr_index  (wr_idx_mux),
    .write_len         (wr_len_mux),
    .i_vflip           (wr_vflip_mux),
    .write_en          (wr_en_mux),
    .write_data        (wr_data_mux)
);

// 应答按所有权分发，避免视频帧的 ack 闯进 BMP 装载流程
assign sd_card_write_req_ack = wr_ack_all & ~vid_wr_own;
assign vf_wr_ack             = wr_ack_all &  vid_wr_own;

// ===================== 层3 视频链（EGV → 2 倍放大 → SDRAM 双缓冲）=====================
egv_reader #(
    .FRAME_CYC        (23'd4_166_667)
) u_egv_reader (
    .clk              (sd_card_clk),
    .rst              (rst_all),
    .i_play           (vid_layer & vid_play_w & vf_ready & sd_ready & ~vid_load_busy),
    .i_fill_ready     (vf_frame_ready),
    .i_sd_ready       (sd_ready),
    .o_sd_read        (egv_sd_read),
    .o_sd_addr        (egv_sd_addr),
    .o_sd_count       (egv_sd_count),
    .i_sd_data        (egv_cli_data),
    .i_sd_data_valid  (egv_cli_dv),
    .i_sd_read_end    (egv_cli_end),
    .o_pix_en         (egv_pix_en),
    .o_pix            (egv_pix),
    .o_frame_start    (egv_fstart),
    .o_aud_en         (egv_aud_en),
    .o_aud_byte       (egv_aud_byte),
    .o_aud_fstart     (egv_afstart),
    .o_frame_no       (egv_frame_no),
    .o_active         (egv_active)
);

video_frame_fill u_video_frame_fill (
    .clk              (sd_card_clk),
    .rst              (rst_all),
    .i_en             (vid_wr_own),
    .i_frame_start    (egv_fstart),
    .i_pix_en         (egv_pix_en),
    .i_pix            (egv_pix),
    .o_wr_req         (vf_wr_req),
    .i_wr_ack         (vf_wr_ack),
    .o_wr_en          (vf_wr_en),
    .o_wr_data        (vf_wr_data),
    .o_wr_len         (vf_wr_len),
    .o_wr_bank        (vf_wr_bank),
    .o_addr_full      (vf_addr_full),
    .i_fin_tgl        (frame_write_toggle_mem),
    .o_disp_bank      (vf_disp_bank),
    .o_ready          (vf_ready),
    .o_frame_ready    (vf_frame_ready),
    .o_busy           (vf_busy),
    .o_frame_end      (vf_frame_end)
);

// 每写出一帧视频翻转一次（资源面板据此显示帧号）
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all)
        vid_ftgl <= 1'b0;
    else if (vf_frame_end)
        vid_ftgl <= ~vid_ftgl;
end

// 视频音轨跨时钟 FIFO（写 100MHz 字节流 / 读 audio_mclk FWFT）
assign vid_aud_on = vid_layer & vid_play_w & vf_ready;

// 首帧画面真正写进 SDRAM 后才放音频：既预填约 1 帧音频，又让第 0 帧声画对齐
reg vid_aud_arm;
always @(posedge sd_card_clk or posedge rst_all) begin
    if (rst_all)
        vid_aud_arm <= 1'b0;
    else if (!vid_aud_on)
        vid_aud_arm <= 1'b0;
    else if (vf_frame_end)
        vid_aud_arm <= 1'b1;
end

egv_audio_fifo u_egv_audio_fifo (
    .i_wclk      (sd_card_clk),
    .i_wrst      (rst_all),
    .i_flush     (~vid_aud_on),
    .i_fstart    (egv_afstart),
    .i_wr_en     (egv_aud_en),
    .i_wr_byte   (egv_aud_byte),
    .o_count     (),
    .i_rclk      (audio_mclk),
    .i_rrst      (rst_all),
    .i_flush_r   (~vid_aud_on_m),
    .i_rd_en     (egv_afifo_rden),
    .o_rd_data   (egv_afifo_data),
    .o_rd_empty  (egv_afifo_empty)
);

// audio_mclk 域准静态同步
reg [1:0] vl_s, vp_s, va_s, vm_s;
always @(posedge audio_mclk or posedge rst_all) begin
    if (rst_all) begin
        vl_s <= 2'd0;
        vp_s <= 2'd0;
        va_s <= 2'd0;
        vm_s <= 2'd0;
    end else begin
        vl_s <= {vl_s[0], vid_layer_v};
        vp_s <= {vp_s[0], vid_play_v};
        va_s <= {va_s[0], vid_aud_on};
        vm_s <= {vm_s[0], vid_aud_arm};
    end
end
assign vid_layer_m  = vl_s[1];
assign vid_play_m   = vp_s[1];
assign vid_aud_on_m = va_s[1];
assign vid_aud_arm_m = vm_s[1];

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

// ===================== 音频：WAV / 视频音轨（ASRC 到 48k）+ I2S 发射 =====================
// 层3 用视频自带音轨（48kHz 立体声，步进 2^32 即 1:1），其余层用 WAV
assign aud_sel_m  = vid_layer_m;
assign aud_data   = aud_sel_m ? egv_afifo_data  : wav_fifo_rd_data;
assign aud_empty  = aud_sel_m ? egv_afifo_empty : wav_fifo_empty;
assign aud_active = aud_sel_m | wav_active;
assign aud_step   = aud_sel_m ? 33'h1_0000_0000 : wav_rate_step;
assign aud_stereo = aud_sel_m ? 1'b1 : wav_stereo;
assign aud_pause  = aud_sel_m ? ~vid_aud_arm_m : ctrl_audio_pause;

assign wav_fifo_rd_en = aud_rden & ~aud_sel_m;
assign egv_afifo_rden = aud_rden &  aud_sel_m;

wav_i2s_source u_wav_i2s_source (
    .I_mclk       (audio_mclk),
    .I_rst        (rst_all),
    .fifo_rd_en   (aud_rden),
    .fifo_rd_data (aud_data),
    .fifo_empty   (aud_empty),
    .i_active     (aud_active),
    .i_pause      (aud_pause),
    .i_step       (aud_step),
    .i_stereo     (aud_stereo),
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
    .I_wav_sel   (aud_active),
    .I_wav_valid (wav_src_valid),
    .I_wav_l     (wav_src_l),
    .I_wav_r     (wav_src_r),
    .I_pause     (aud_pause),
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

// Goertzel 32 频段频谱分析（与 I2S_receiver 同域，供 OSD 频谱图）
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
