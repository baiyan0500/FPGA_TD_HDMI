
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [4:0]   SCAN_TARGET_COUNT = 5'd16
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input                       i_next_en,        // 层1 才允许 KEY2 手动切图
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,
    output      [4:0]           img_count,
    output                      sd_ready,
    output                      scan_done_o,

    // 当前显示图的源尺寸（100MHz 域 BCD：{千,百,十,个}，提交新图后更新）
    // + 更新 toggle（跨域握手，底栏据此标注 "源尺寸>640x480"）
    output reg  [15:0]          o_src_w_bcd,
    output reg  [15:0]          o_src_h_bcd,
    output reg                  o_src_tgl,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    input                       fade_swap,       // 淡出完成 toggle（video_clk 域，跨域同步）
    output reg                  fade_req,        // 过渡请求 toggle（给 fade_ctrl）
    output reg [23:0]           shown_bcd,       // 已播放图片张数（6 位 BCD）

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    output                      SD_nCS,
    output                      SD_DCLK,
    output                      SD_MOSI,
    input                       SD_MISO,

    // ---- WAV 播放（层3）----
    input                       wav_pause,        // 暂停电平（video_clk 域，内部 2 级同步）
    output                      wav_active,       // WAV 播放有效（100MHz 域电平）
    output      [32:0]          wav_rate_step,    // ASRC 步进（33bit）
    output                      wav_stereo,       // 1=立体声
    input                       wav_rd_clk,       // FIFO 读时钟（audio_mclk 12.288MHz）
    input                       wav_fifo_rd_en,   // FIFO 读使能（audio_mclk 域）
    output      [15:0]          wav_fifo_rd_data, // FIFO 读数据（FWFT）
    output                      wav_fifo_empty,    // FIFO 空标志

    // ---- 视频客户端（SW3 层）----
    input                       i_video_play,     // 视频模式：BMP 装载停、WAV 让出总线
    input                       i_egv_sd_read,
    input  [31:0]               i_egv_sd_addr,
    input  [15:0]               i_egv_sd_count,   //视频客户端连续读扇区数
    output                      o_cli_data_valid,
    output [7:0]                o_cli_data,
    output                      o_cli_read_end,
    output                      o_load_busy
);

wire key_next_press;
reg [2:0] auto_play_sync;
wire      auto_play_level = auto_play_sync[2];

wire             sd_sec_read;
wire [31:0]      sd_sec_read_addr;
wire [7:0]       sd_sec_read_data;
wire             sd_sec_read_data_valid;
wire             sd_sec_read_end;
wire [3:0]       state_code_i;
wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire [15:0]      src_width;
wire [15:0]      src_height;
wire             scale_wr_en;
wire [23:0]      scale_data;
wire             scale_almost_full;
wire             sd_init_done;
wire             bmp_ready;
wire             scan_done;
wire             scan_found_valid;
wire [31:0]      scan_found_sector;
wire [4:0]       scan_found_total;

// ---- WAV 客户端 ----
wire             wav_found;
wire [31:0]      wav_start_sector;
wire             wav_bus_req;
wire             wav_sd_read;
wire [31:0]      wav_sd_addr;
wire             wav_data_valid;
wire             wav_read_end;
wire             wav_pause_s;
reg  [1:0]       wav_pause_sync;

// ---- SD 总线仲裁 ----
reg              grant_wav;
reg              bmp_rd_busy;
reg              wav_rd_busy;
// 视频独占请求（模式电平）与"当前总线实际归属视频"必须分开：
// i_video_play 由 video_frame_fill 的组合状态给出，可在扇区中途拉高。
// 若直接用它切换读请求/数据口，视频客户端会先收到 BMP 在途扇区的尾部字节，
// 逐字节计数错位→整段视频图像错位、音频错乱。因此与 WAV 一样只在扇区边界交接。
wire             egv_req = i_video_play;
reg              egv_owns_r;
wire             want_wav = wav_bus_req && !egv_req && !egv_owns_r;
wire             egv_owns = egv_owns_r;
// 扇区边界：BMP/WAV 均无在途扇区、无挂起请求、WAV 未被授予
wire             bus_idle = !bmp_rd_busy && !sd_sec_read && !grant_wav &&
                            !wav_rd_busy && !wav_sd_read;
// BMP 数据/有效/结束再寄存一级：归属判决（grant_wav 扇出 62、egv_owns）
// 与 bmp_read 的字节计数 CE 之间必须隔触发器，
// 否则该锥形链 10.9ns 直接成为 setup 最差路径。
reg  [7:0]       bmp_d_q;
reg              bmp_v_q;
reg              bmp_e_q;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_d_q <= 8'd0;
        bmp_v_q <= 1'b0;
        bmp_e_q <= 1'b0;
    end else begin
        bmp_d_q <= sd_sec_read_data;
        bmp_v_q <= !grant_wav && !egv_owns && sd_sec_read_data_valid;
        bmp_e_q <= !grant_wav && !egv_owns && sd_sec_read_end;
    end
end

wire             bmp_data_valid_g = bmp_v_q;
wire             bmp_read_end_g   = bmp_e_q;
wire             sd_sec_read_mux  = grant_wav ? wav_sd_read :
                                    (egv_owns ? i_egv_sd_read : sd_sec_read);
wire [31:0]      sd_sec_addr_mux  = grant_wav ? wav_sd_addr :
                                    (egv_owns ? i_egv_sd_addr : sd_sec_read_addr);
// BMP / WAV 客户端仍按单扇区读（CMD17），只有视频客户端用 CMD18 连续读
wire [15:0]      sd_sec_count_mux = egv_owns ? i_egv_sd_count : 16'd1;
// WAV 客户端数据/结束信号按 grant 门控分发（此前缺失驱动导致 wav_rd_busy 永不清零、总线锁死）
assign wav_data_valid = grant_wav && sd_sec_read_data_valid;
assign wav_read_end   = grant_wav && sd_sec_read_end;
// 视频客户端独占（grant_wav 在 i_video_play 时无法拉起）
assign o_cli_data_valid = !grant_wav && egv_owns && sd_sec_read_data_valid;
assign o_cli_data       = sd_sec_read_data;
assign o_cli_read_end   = !grant_wav && egv_owns && sd_sec_read_end;

reg              vp_q;                 // i_video_play 寄存一级：起点从 st 组合输出挪到触发器，
                                       // 否则 vf_busy→i_video_play→装载判决链 10.9ns 违例
reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [4:0]        img_found_count;      // 0..16（比表项多 1，便于判断"表已满"）
reg [3:0]        img_idx;              // 当前真正显示中的图片编号
reg [3:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
// 图片起始扇区表（16 张）。本卡 SCAN_MAX_SECTOR=131071，18bit 足够（256MB 上限），
// 比 32bit 省 224 个触发器——当前 slice 占用已超 90%
reg [17:0]       img_sector0;
reg [17:0]       img_sector1;
reg [17:0]       img_sector2;
reg [17:0]       img_sector3;
reg [17:0]       img_sector4;
reg [17:0]       img_sector5;
reg [17:0]       img_sector6;
reg [17:0]       img_sector7;
reg [17:0]       img_sector8;
reg [17:0]       img_sector9;
reg [17:0]       img_sector10;
reg [17:0]       img_sector11;
reg [17:0]       img_sector12;
reg [17:0]       img_sector13;
reg [17:0]       img_sector14;
reg [17:0]       img_sector15;
reg              next_req_pending;
reg              load_busy;

assign o_load_busy = load_busy;

reg [31:0]       load_timeout_cnt;

reg              load_abort;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;
reg              swap_pending;         // 正在等待淡出完成（fade_swap 边沿）
reg              img_shown_pulse;      // 切图脉冲（播放计数 +1）
reg              load_active_seen;     // bmp_read 已真正离开 IDLE（装载确实启动过）
reg              wr_req_seen;          // 本次装载已发出 write_req（header 匹配过）
reg [3:0]        fail_idx;             // 最近一次装载失败的图片索引
reg              fail_valid;           // fail_idx 有效：下次切图从它的下一张继续尝试

// 装载候选：把“下一张索引 → 扇区查表”拆成两级寄存。原来 fail_valid 一拍内要走
// 5 位加法 + 16 选 1 的 32 位查表 + 装载选择，100MHz 下组合延迟 >11ns
reg [3:0]        cand_idx;
reg [31:0]       cand_sector;
reg [1:0]        cand_buf;
reg [2:0]        cand_idle;            // 空闲拍数：保证候选值在发起装载前已稳定
wire             cand_ok = cand_idle[2];

// WAV 总线授予看门狗：正常一次补水（最多 3 个扇区）约 0.5ms，超过 1.5ms
// 视为在途标志卡死（sd_sec_read 撤销早于 SD 核采样会丢掉请求），强制收回总线
reg [17:0]       wav_grant_cnt;
// bmp 侧同型看门狗：在途扇区超过 1.5ms 仍无 read_end，强制清 bmp_rd_busy，
// 否则 WAV 因 !bmp_rd_busy 永远拿不到总线，整机卡死在等 1s 装载超时
reg [17:0]       bmp_busy_cnt;

// 源尺寸二进制 → BCD（double dabble，11 位输入，11 拍完成）
reg [26:0]       dab_w;                // {BCD[15:0], bin[10:0]}
reg [26:0]       dab_h;
reg [3:0]        dab_cnt;
reg              dab_busy;
reg              src_commit;           // 提交新图（与 img_shown_pulse 同拍）
reg [15:0]       src_w_lat;
reg [15:0]       src_h_lat;

function [3:0] dab_add3;
    input [3:0] d;
    begin
        dab_add3 = (d >= 4'd5) ? (d + 4'd3) : d;
    end
endfunction

wire [26:0] dab_w_add = { dab_add3(dab_w[26:23]), dab_add3(dab_w[22:19]),
                          dab_add3(dab_w[18:15]), dab_add3(dab_w[14:11]), dab_w[10:0] };
wire [26:0] dab_h_add = { dab_add3(dab_h[26:23]), dab_add3(dab_h[22:19]),
                          dab_add3(dab_h[18:15]), dab_add3(dab_h[14:11]), dab_h[10:0] };
wire [26:0] dab_w_nxt = {dab_w_add[25:0], 1'b0};
wire [26:0] dab_h_nxt = {dab_h_add[25:0], 1'b0};

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

// 同步 video_clk 域的 fade_swap
reg [2:0]        fade_swap_sync;
wire             fade_swap_edge;

wire auto_tick;
wire [3:0] next_base;        // 切图基准：上次失败的图 → 从它继续，否则从当前显示图继续
wire [3:0] next_from_current;

assign write_en   = scale_wr_en;
assign write_data = {scale_data[23:16], scale_data[15:8], scale_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));   // 1 秒间隔
assign next_base        = fail_valid ? fail_idx : img_idx;
assign next_from_current = next_index_limited(next_base, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign fade_swap_edge      = fade_swap_sync[2] ^ fade_swap_sync[1];
assign state_code = state_code_i;
assign img_count  = img_found_count;
assign sd_ready   = sd_init_done;
assign scan_done_o = scan_done;

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (50)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

// key_auto 现在是从 ctrl 来的"自动播放电平"（跨域），3 级同步即可，无需去抖
always @(posedge clk or posedge rst) begin
    if (rst)
        auto_play_sync <= 3'd0;
    else
        auto_play_sync <= {auto_play_sync[1:0], key_auto};
end

// WAV 暂停电平同步（video_clk → 100MHz）
always @(posedge clk or posedge rst) begin
    if (rst)
        wav_pause_sync <= 2'b00;
    else
        wav_pause_sync <= {wav_pause_sync[0], wav_pause};
end
assign wav_pause_s = wav_pause_sync[1];

// write_req_ack 由 ext_mem_clk 域产生，bmp_read 在 sd_card_clk 域直接采样
// 属于跨域握手。ack 在 write_req 撤销前一直保持高，2 级同步后使用，
// 既消除亚稳态采样风险，也让 ext_mem↔sd 域可按异步组收敛。
reg  [1:0] wr_ack_sync;
always @(posedge clk or posedge rst) begin
    if (rst)
        wr_ack_sync <= 2'b00;
    else
        wr_ack_sync <= {wr_ack_sync[0], write_req_ack};
end
wire write_req_ack_s = wr_ack_sync[1];

// ---------------------------------------------------------------------------
// SD 总线仲裁：bmp_read 与 sd_card_wav 共享 sd_card_top
//   · 切换仅在"双方均无在途扇区且无挂起请求"的拍发生（扇区边界）
//   · want_wav=1 时 bmp_read 被 i_stall 背压，在扇区边界让出总线
//   · bmp_rd_busy/wav_rd_busy 跟踪在途扇区，保证 read_end 分发回发起方
//   · wav_grant_cnt / bmp_busy_cnt 看门狗：任一方的在途标志超过 1.5ms
//     （≈9 个扇区，正常单扇区约 180µs）无进展即视为卡死，强制释放，
//     避免两方互等（WAV 等 !bmp_rd_busy，bmp 等 want_wav 撤销）形成死锁
// ---------------------------------------------------------------------------
wire wav_grant_timeout = (wav_grant_cnt >= 18'd150_000);
wire bmp_busy_timeout  = (bmp_busy_cnt >= 18'd150_000);

always @(posedge clk or posedge rst) begin
    if (rst) begin
        grant_wav    <= 1'b0;
        bmp_rd_busy  <= 1'b0;
        wav_rd_busy  <= 1'b0;
        egv_owns_r   <= 1'b0;
        wav_grant_cnt <= 18'd0;
        bmp_busy_cnt <= 18'd0;
    end else begin
        // 授予期间无扇区完成就累加（wav_read_end 即"有进展"）
        if (!grant_wav || wav_read_end)
            wav_grant_cnt <= 18'd0;
        else
            wav_grant_cnt <= wav_grant_cnt + 18'd1;

        // bmp 侧在途无进展计数（背压期间 bmp_rd_busy=0，不计时）
        if (!bmp_rd_busy || bmp_read_end_g)
            bmp_busy_cnt <= 18'd0;
        else
            bmp_busy_cnt <= bmp_busy_cnt + 18'd1;

        // bmp 侧在途跟踪
        if (!grant_wav && !egv_owns_r && !bmp_rd_busy && sd_sec_read)
            bmp_rd_busy <= 1'b1;
        else if (!grant_wav && !egv_owns_r && bmp_read_end_g)
            bmp_rd_busy <= 1'b0;
        else if (!grant_wav && !egv_owns_r && bmp_busy_timeout)
            bmp_rd_busy <= 1'b0;    // 卡死：清在途标志，让 WAV 能拿到总线

        // wav 侧在途跟踪
        if (grant_wav && !wav_rd_busy && wav_sd_read)
            wav_rd_busy <= 1'b1;
        else if (grant_wav && wav_read_end)
            wav_rd_busy <= 1'b0;

        // 视频独占交接：只在扇区边界接管，离开时等当前 CMD18 批次结束
        if (!egv_owns_r) begin
            if (egv_req && bus_idle)
                egv_owns_r <= 1'b1;
        end else if (!egv_req && !i_egv_sd_read) begin
            egv_owns_r <= 1'b0;
        end

        // 总线授予切换
        if (!grant_wav && want_wav && !bmp_rd_busy && !sd_sec_read) begin
            grant_wav     <= 1'b1;
            wav_grant_cnt <= 18'd0;
        end else if (grant_wav && wav_grant_timeout) begin
            grant_wav     <= 1'b0;      // 卡死：强制收回（下一拍重新竞争）
            wav_rd_busy   <= 1'b0;
            wav_grant_cnt <= 18'd0;
        end else if (grant_wav && !want_wav && !wav_rd_busy && !wav_sd_read) begin
            grant_wav     <= 1'b0;
        end
    end
end

function [3:0] next_index_limited;
    input [3:0] cur;
    input [4:0] count;
    begin
        if (count == 5'd0)
            next_index_limited = 4'd0;
        else if (({1'b0, cur} + 5'd1) >= count)
            next_index_limited = 4'd0;
        else
            next_index_limited = cur + 4'd1;
    end
endfunction

function [31:0] sector_lut;
    input [3:0] idx;
    begin
        case (idx)
            4'd0:  sector_lut = {14'd0, img_sector0};
            4'd1:  sector_lut = {14'd0, img_sector1};
            4'd2:  sector_lut = {14'd0, img_sector2};
            4'd3:  sector_lut = {14'd0, img_sector3};
            4'd4:  sector_lut = {14'd0, img_sector4};
            4'd5:  sector_lut = {14'd0, img_sector5};
            4'd6:  sector_lut = {14'd0, img_sector6};
            4'd7:  sector_lut = {14'd0, img_sector7};
            4'd8:  sector_lut = {14'd0, img_sector8};
            4'd9:  sector_lut = {14'd0, img_sector9};
            4'd10: sector_lut = {14'd0, img_sector10};
            4'd11: sector_lut = {14'd0, img_sector11};
            4'd12: sector_lut = {14'd0, img_sector12};
            4'd13: sector_lut = {14'd0, img_sector13};
            4'd14: sector_lut = {14'd0, img_sector14};
            4'd15: sector_lut = {14'd0, img_sector15};
            default: sector_lut = {14'd0, img_sector0};
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

// 候选流水：fail_valid/img_idx → 索引，再一级 → 扇区查表。
// 输入只在装载结束（load_busy 下降）时变化，空闲 3 拍后候选值必定有效
always @(posedge clk or posedge rst) begin
    if (rst) begin
        cand_idx    <= 4'd0;
        cand_sector <= 32'd0;
        cand_buf    <= 2'd0;
        cand_idle   <= 3'b000;
    end else begin
        cand_idx    <= next_from_current;
        cand_sector <= sector_lut(cand_idx);
        cand_buf    <= next_buf_lut(disp_buf_idx, display_valid);
        cand_idle   <= {cand_idle[1:0], ~load_busy};
    end
end

// 视频播放为秒级准静态模式，装载判决用寄存值：发出请求的历史分支都在
// 视频起播后至少 1 拍才关闭，期间 bmp_read 仍由 i_stall（未寄存）立即拦住
always @(posedge clk or posedge rst) begin
    if (rst) vp_q <= 1'b0;
    else     vp_q <= i_video_play;
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        fade_swap_sync        <= 3'b000;
        swap_pending          <= 1'b0;
        fade_req              <= 1'b0;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 5'd0;
        img_idx               <= 4'd0;
        load_idx              <= 4'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 18'd0;
        img_sector1           <= 18'd0;
        img_sector2           <= 18'd0;
        img_sector3           <= 18'd0;
        img_sector4           <= 18'd0;
        img_sector5           <= 18'd0;
        img_sector6           <= 18'd0;
        img_sector7           <= 18'd0;
        img_sector8           <= 18'd0;
        img_sector9           <= 18'd0;
        img_sector10          <= 18'd0;
        img_sector11          <= 18'd0;
        img_sector12          <= 18'd0;
        img_sector13          <= 18'd0;
        img_sector14          <= 18'd0;
        img_sector15          <= 18'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        load_active_seen      <= 1'b0;
        wr_req_seen           <= 1'b0;
        fail_idx              <= 4'd0;
        fail_valid            <= 1'b0;
        src_commit            <= 1'b0;
        src_w_lat             <= 16'd0;
        src_h_lat             <= 16'd0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        fade_swap_sync   <= {fade_swap_sync[1:0], fade_swap};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        img_shown_pulse  <= 1'b0;
        src_commit       <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 5'd0;
            img_idx               <= 4'd0;
            load_idx              <= 4'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 18'd0;
            img_sector1           <= 18'd0;
            img_sector2           <= 18'd0;
            img_sector3           <= 18'd0;
            img_sector4           <= 18'd0;
            img_sector5           <= 18'd0;
            img_sector6           <= 18'd0;
            img_sector7           <= 18'd0;
            img_sector8           <= 18'd0;
            img_sector9           <= 18'd0;
            img_sector10          <= 18'd0;
            img_sector11          <= 18'd0;
            img_sector12          <= 18'd0;
            img_sector13          <= 18'd0;
            img_sector14          <= 18'd0;
            img_sector15          <= 18'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            load_timeout_cnt      <= 32'd0;
            load_abort            <= 1'b0;
            source_done_seen      <= 1'b0;
            write_done_seen       <= 1'b0;
            swap_pending          <= 1'b0;
            fade_req              <= 1'b0;
            display_valid         <= 1'b0;
            load_active_seen      <= 1'b0;
            wr_req_seen           <= 1'b0;
            fail_idx              <= 4'd0;
            fail_valid            <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    5'd0:  img_sector0  <= scan_found_sector[17:0];
                    5'd1:  img_sector1  <= scan_found_sector[17:0];
                    5'd2:  img_sector2  <= scan_found_sector[17:0];
                    5'd3:  img_sector3  <= scan_found_sector[17:0];
                    5'd4:  img_sector4  <= scan_found_sector[17:0];
                    5'd5:  img_sector5  <= scan_found_sector[17:0];
                    5'd6:  img_sector6  <= scan_found_sector[17:0];
                    5'd7:  img_sector7  <= scan_found_sector[17:0];
                    5'd8:  img_sector8  <= scan_found_sector[17:0];
                    5'd9:  img_sector9  <= scan_found_sector[17:0];
                    5'd10: img_sector10 <= scan_found_sector[17:0];
                    5'd11: img_sector11 <= scan_found_sector[17:0];
                    5'd12: img_sector12 <= scan_found_sector[17:0];
                    5'd13: img_sector13 <= scan_found_sector[17:0];
                    5'd14: img_sector14 <= scan_found_sector[17:0];
                    5'd15: img_sector15 <= scan_found_sector[17:0];
                    default: ;
                endcase

                if (img_found_count < 5'd16)
                    img_found_count <= img_found_count + 5'd1;
            end

            // 装载确实启动过（bmp_read 离开过 IDLE）、且发出过 write_req（header 匹配），
            // bmp_read 回到 IDLE 才算"源图送完"。修复装载启动瞬间 bmp_ready 尚为 1 导致的误置位
            if (load_busy && !bmp_ready)
                load_active_seen <= 1'b1;
            if (load_busy && write_req)
                wr_req_seen <= 1'b1;

            if (load_busy && load_active_seen && bmp_ready && !swap_pending && !load_start_pulse) begin
                if (wr_req_seen)
                    source_done_seen <= 1'b1;   // 源读完，等整帧写完
                else begin
                    // header 不匹配（坏图）：立即放弃，不等 1s 超时；下次切图自动跳到下一张
                    load_busy   <= 1'b0;
                    load_abort  <= 1'b1;
                    fail_idx    <= load_idx;
                    fail_valid  <= 1'b1;
                end
            end

            // 记住写帧完成脉冲，避免“先写完后源结束”导致脉冲丢失而卡死
            if (load_busy && write_finish_pulse)
                write_done_seen <= 1'b1;

            // 只有“源图送完 + 整帧写完”都满足，才提交新图并切换显示缓冲区
            if (load_busy && source_done_seen && write_done_seen && !first_image_committed) begin
                // 首图：直接硬切（黑屏到首图，无需淡出）
                load_busy             <= 1'b0;
                load_timeout_cnt      <= 32'd0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                img_shown_pulse       <= 1'b1;
                fail_valid            <= 1'b0;
                src_w_lat             <= src_width;
                src_h_lat             <= src_height;
                src_commit            <= 1'b1;
            end else if (load_busy && source_done_seen && write_done_seen && first_image_committed && !swap_pending) begin
                // 后续切图：先触发淡出，等 fade_swap 边沿再切显示缓冲
                source_done_seen <= 1'b0;
                write_done_seen  <= 1'b0;
                fade_req         <= ~fade_req;      // 请求淡出
                swap_pending     <= 1'b1;
            end else if (swap_pending && fade_swap_edge) begin
                // 淡出完成：切显示缓冲 + 触发淡入
                swap_pending     <= 1'b0;
                load_busy        <= 1'b0;
                load_timeout_cnt <= 32'd0;
                disp_buf_idx     <= pending_buf_idx;
                img_idx          <= load_idx;
                fade_req         <= ~fade_req;      // 请求淡入
                img_shown_pulse  <= 1'b1;
                fail_valid       <= 1'b0;
                src_w_lat        <= src_width;
                src_h_lat        <= src_height;
                src_commit       <= 1'b1;
            end else if (load_busy) begin
                // 超时覆盖 swap_pending：防止 fade 握手丢失时 swap_pending 永久挂起导致 K2 彻底失效。
                // 3s 阈值 > 最坏正常时长（装载约 0.6s + 全程转场约 0.54s）。
                // 注意：不能再用 want_wav 冻结计数——WAV 补水若长期霸占总线，
                // 冻结会让"装载卡死"永远不恢复，上板表现为播几张后画面卡住。
                // bmp_busy_timeout：SD 核丢了本次扇区请求（1.5ms 无 end）。
                // 此时 bmp 一直拉着 sd_sec_read，光清 bmp_rd_busy 也抢不回总线，
                // 直接按"坏图"处理跳过，免得整机冻结到 3s 超时。
                if ((load_timeout_cnt > 32'd300_000_000) || bmp_busy_timeout) begin
                    // 超时（例如读到坏图或截断的文件导致死锁），强制释放 busy 以恢复按键响应
                    load_busy             <= 1'b0;
                    load_timeout_cnt      <= 32'd0;
                    source_done_seen      <= 1'b0;
                    write_done_seen       <= 1'b0;
                    load_abort            <= 1'b1;
                    swap_pending          <= 1'b0;
                    fail_idx              <= load_idx;
                    fail_valid            <= 1'b1;
                end else begin
                    load_timeout_cnt <= load_timeout_cnt + 32'd1;
                end
            end else begin
                load_timeout_cnt <= 32'd0;
            end

            // 上电后自动发起一次"扫描前 16 张 BMP"
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 5'd0;
                img_idx               <= 4'd0;
                load_idx              <= 4'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_seen       <= 1'b0;
            end else begin
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (key_next_press && i_next_en && scan_done && (img_found_count != 5'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关（电平控制，来自 ctrl 的 o_auto_play）
                if (auto_play_level != auto_play_en)
                    auto_cnt <= 32'd0;
                auto_play_en <= auto_play_level;

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 5'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 首图自动加载到 buffer0（若首图坏则沿 fail 链继续尝试后续图片）
                if (scan_done && !first_image_committed && bmp_ready && !load_busy && !vp_q && (img_found_count != 5'd0) && cand_ok) begin
                    load_idx         <= fail_valid ? cand_idx : 4'd0;
                    load_sector      <= fail_valid ? cand_sector : {14'd0, img_sector0};
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_active_seen <= 1'b0;
                    wr_req_seen      <= 1'b0;
                    fail_valid       <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && !vp_q && next_req_pending && (img_found_count != 5'd0) && cand_ok) begin
                    load_idx         <= cand_idx;
                    load_sector      <= cand_sector;
                    pending_buf_idx  <= cand_buf;
                    write_buf_idx    <= cand_buf;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_active_seen <= 1'b0;
                    wr_req_seen      <= 1'b0;
                    fail_valid       <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 自动播放下一张：同样写到“非当前显示”的另一块 buffer
                else if (scan_done && bmp_ready && display_valid && !load_busy && !vp_q && auto_play_en && auto_tick && (img_found_count > 5'd1) && cand_ok) begin
                    load_idx         <= cand_idx;
                    load_sector      <= cand_sector;
                    pending_buf_idx  <= cand_buf;
                    write_buf_idx    <= cand_buf;
                    load_start_pulse <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_seen  <= 1'b0;
                    load_active_seen <= 1'b0;
                    wr_req_seen      <= 1'b0;
                    fail_valid       <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_ready),

    .scan_start             (scan_start_pulse),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (scan_done),
    .scan_found_valid       (scan_found_valid),
    .scan_found_sector      (scan_found_sector),
    .scan_found_total       (scan_found_total),
    .wav_found              (wav_found),
    .wav_start_sector       (wav_start_sector),

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack_s),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (bmp_d_q),
    .sd_sec_read_data_valid (bmp_data_valid_g),
    .sd_sec_read_end        (bmp_read_end_g),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .src_width              (src_width),
    .src_height             (src_height),
    .i_stall                (scale_almost_full | want_wav | i_video_play | egv_owns_r)
);

scaler u_scaler(
    .clk         (clk),
    .rst         (rst),
    .start       (write_req_ack),
    .src_w       (src_width),
    .src_h       (src_height),
    .src_en      (bmp_data_wr_en),
    .src_data    (bmp_data),
    .almost_full (scale_almost_full),
    .dst_en      (scale_wr_en),
    .dst_data    (scale_data),
    .done        ()
);

sd_card_top sd_card_top_m0(
    .clk                    (clk),
    .rst                    (rst),
    .SD_nCS                 (SD_nCS),
    .SD_DCLK                (SD_DCLK),
    .SD_MOSI                (SD_MOSI),
    .SD_MISO                (SD_MISO),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (sd_sec_read_mux),
    .sd_sec_read_addr       (sd_sec_addr_mux),
    .sd_sec_read_count      (sd_sec_count_mux),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
);

// ---------------------------------------------------------------------------
// WAV 解析 + 播放补水客户端（与 bmp_read 共享 sd_card_top，见上方仲裁器）
// ---------------------------------------------------------------------------
sd_card_wav #(
    .CLK_FREQ_HZ            (CLK_FREQ_HZ)
) u_sd_card_wav (
    .clk                    (clk),
    .rst                    (rst),
    .i_scan_done            (scan_done),
    .i_wav_found            (wav_found),
    .i_wav_start_sector     (wav_start_sector),
    .i_pause                (wav_pause_s | i_video_play),
    .o_bus_req              (wav_bus_req),
    .i_bus_grant            (grant_wav),
    .sd_sec_read            (wav_sd_read),
    .sd_sec_addr            (wav_sd_addr),
    .sd_sec_data            (sd_sec_read_data),
    .sd_sec_data_valid      (wav_data_valid),
    .sd_sec_read_end        (wav_read_end),
    .fifo_rd_clk            (wav_rd_clk),
    .fifo_rd_en             (wav_fifo_rd_en),
    .fifo_rd_data           (wav_fifo_rd_data),
    .fifo_empty             (wav_fifo_empty),
    .o_active               (wav_active),
    .o_rate_step            (wav_rate_step),
    .o_stereo               (wav_stereo)
);

// ---- 播放次数 BCD 加 1（6 位 BCD）----
wire [3:0] bcd_d0 = shown_bcd[3:0];
wire [3:0] bcd_d1 = shown_bcd[7:4];
wire [3:0] bcd_d2 = shown_bcd[11:8];
wire [3:0] bcd_d3 = shown_bcd[15:12];
wire [3:0] bcd_d4 = shown_bcd[19:16];
wire [3:0] bcd_d5 = shown_bcd[23:20];

wire bcd_c0 = (bcd_d0 == 4'd9);
wire bcd_c1 = (bcd_d1 == 4'd9) & bcd_c0;
wire bcd_c2 = (bcd_d2 == 4'd9) & bcd_c1;
wire bcd_c3 = (bcd_d3 == 4'd9) & bcd_c2;
wire bcd_c4 = (bcd_d4 == 4'd9) & bcd_c3;

wire [3:0] bcd_n0 = bcd_c0 ? 4'd0 : bcd_d0 + 4'd1;
wire [3:0] bcd_n1 = bcd_c0 ? (bcd_c1 ? 4'd0 : bcd_d1 + 4'd1) : bcd_d1;
wire [3:0] bcd_n2 = bcd_c1 ? (bcd_c2 ? 4'd0 : bcd_d2 + 4'd1) : bcd_d2;
wire [3:0] bcd_n3 = bcd_c2 ? (bcd_c3 ? 4'd0 : bcd_d3 + 4'd1) : bcd_d3;
wire [3:0] bcd_n4 = bcd_c3 ? (bcd_c4 ? 4'd0 : bcd_d4 + 4'd1) : bcd_d4;
wire [3:0] bcd_n5 = bcd_c4 ? ((bcd_d5 == 4'd9) ? 4'd0 : bcd_d5 + 4'd1) : bcd_d5;

always @(posedge clk or posedge rst) begin
    if (rst)
        shown_bcd <= 24'd0;
    else if (img_shown_pulse)
        shown_bcd <= {bcd_n5, bcd_n4, bcd_n3, bcd_n2, bcd_n1, bcd_n0};
end

// ---- 源尺寸二进制 → BCD（double dabble，11 拍）----
// 转换完成后再翻转 o_src_tgl，保证 video 域锁存到的 BCD 一定已经稳定
always @(posedge clk or posedge rst) begin
    if (rst) begin
        dab_w       <= 27'd0;
        dab_h       <= 27'd0;
        dab_cnt     <= 4'd0;
        dab_busy    <= 1'b0;
        o_src_w_bcd <= 16'h0640;
        o_src_h_bcd <= 16'h0480;
        o_src_tgl   <= 1'b0;
    end else if (src_commit) begin
        dab_w    <= {16'd0, src_w_lat[10:0]};
        dab_h    <= {16'd0, src_h_lat[10:0]};
        dab_cnt  <= 4'd0;
        dab_busy <= 1'b1;
    end else if (dab_busy) begin
        if (dab_cnt == 4'd11) begin
            dab_busy    <= 1'b0;
            o_src_w_bcd <= dab_w[26:11];
            o_src_h_bcd <= dab_h[26:11];
            o_src_tgl   <= ~o_src_tgl;
        end else begin
            dab_w   <= dab_w_nxt;
            dab_h   <= dab_h_nxt;
            dab_cnt <= dab_cnt + 4'd1;
        end
    end
end

endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule
