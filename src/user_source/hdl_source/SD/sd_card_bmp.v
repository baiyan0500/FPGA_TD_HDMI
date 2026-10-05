
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd6
)(
    input                       clk,
    input                       rst,
    input                       key_next,
    input                       key_auto,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg                  display_valid,
    output      [3:0]           state_code,

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
    input                       SD_MISO
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
wire [2:0]       scan_found_total;

reg              scan_start_pulse;
reg              load_start_pulse;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg              auto_play_en;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [2:0]        img_idx;              // 当前真正显示中的图片编号
reg [2:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg [31:0]       img_sector4;
reg [31:0]       img_sector5;
reg              next_req_pending;
reg              load_busy;
reg [31:0]       load_timeout_cnt;

reg              load_abort;

// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;
reg              write_done_seen;
reg              swap_pending;         // 正在等待淡出完成（fade_swap 边沿）
reg              img_shown_pulse;      // 切图脉冲（播放计数 +1）
reg              load_active_seen;     // bmp_read 已真正离开 IDLE（装载确实启动过）
reg              wr_req_seen;          // 本次装载已发出 write_req（header 匹配过）
reg [2:0]        fail_idx;             // 最近一次装载失败的图片索引
reg              fail_valid;           // fail_idx 有效：下次切图从它的下一张继续尝试

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

// 同步 video_clk 域的 fade_swap
reg [2:0]        fade_swap_sync;
wire             fade_swap_edge;

wire auto_tick;
wire [2:0] next_base;        // 切图基准：上次失败的图 → 从它继续，否则从当前显示图继续
wire [2:0] next_from_current;

assign write_en   = scale_wr_en;
assign write_data = {scale_data[23:16], scale_data[15:8], scale_data[7:0], 8'b0};
assign auto_tick  = (auto_cnt == (CLK_FREQ_HZ - 1));   // 1 秒间隔
assign next_base        = fail_valid ? fail_idx : img_idx;
assign next_from_current = next_index_limited(next_base, img_found_count);
assign write_finish_pulse = wrfin_tgl_sync[2] ^ wrfin_tgl_sync[1];
assign fade_swap_edge      = fade_swap_sync[2] ^ fade_swap_sync[1];
assign state_code = state_code_i;

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

function [2:0] next_index_limited;
    input [2:0] cur;
    input [2:0] count;
    begin
        case (count)
            3'd0: next_index_limited = 3'd0;
            3'd1: next_index_limited = 3'd0;
            3'd2: next_index_limited = (cur == 3'd1) ? 3'd0 : (cur + 3'd1);
            3'd3: next_index_limited = (cur == 3'd2) ? 3'd0 : (cur + 3'd1);
            3'd4: next_index_limited = (cur == 3'd3) ? 3'd0 : (cur + 3'd1);
            3'd5: next_index_limited = (cur == 3'd4) ? 3'd0 : (cur + 3'd1);
            default: next_index_limited = (cur == 3'd5) ? 3'd0 : (cur + 3'd1);
        endcase
    end
endfunction

function [31:0] sector_lut;
    input [2:0] idx;
    begin
        case (idx)
            3'd0: sector_lut = img_sector0;
            3'd1: sector_lut = img_sector1;
            3'd2: sector_lut = img_sector2;
            3'd3: sector_lut = img_sector3;
            3'd4: sector_lut = img_sector4;
            3'd5: sector_lut = img_sector5;
            default: sector_lut = img_sector0;
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
        img_found_count       <= 3'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        img_sector4           <= 32'd0;
        img_sector5           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        load_timeout_cnt      <= 32'd0;
        load_abort            <= 1'b0;
        source_done_seen      <= 1'b0;
        write_done_seen       <= 1'b0;
        display_valid         <= 1'b0;
        load_active_seen      <= 1'b0;
        wr_req_seen           <= 1'b0;
        fail_idx              <= 3'd0;
        fail_valid            <= 1'b0;
    end else begin
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        fade_swap_sync   <= {fade_swap_sync[1:0], fade_swap};
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        load_abort       <= 1'b0;
        img_shown_pulse  <= 1'b0;

        if (!sd_init_done) begin
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            img_sector4           <= 32'd0;
            img_sector5           <= 32'd0;
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
            fail_idx              <= 3'd0;
            fail_valid            <= 1'b0;
        end else begin
            // 扫描阶段缓存前 4 张图的起始 sector
            if (scan_found_valid) begin
                case (img_found_count)
                    3'd0: img_sector0 <= scan_found_sector;
                    3'd1: img_sector1 <= scan_found_sector;
                    3'd2: img_sector2 <= scan_found_sector;
                    3'd3: img_sector3 <= scan_found_sector;
                    3'd4: img_sector4 <= scan_found_sector;
                    3'd5: img_sector5 <= scan_found_sector;
                    default: ;
                endcase

                if (img_found_count < 3'd6)
                    img_found_count <= img_found_count + 3'd1;
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
            end else if (load_busy) begin
                // 超时覆盖 swap_pending：防止 fade 握手丢失时 swap_pending 永久挂起导致 K2 彻底失效。
                // 2s 阈值 > 最坏正常时长（装载约 0.5s + fade 全程转场约 0.54s）
                if (load_timeout_cnt > 32'd200_000_000) begin
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

            // 上电后自动发起一次“扫描前 6 张 BMP”
            if (!scan_kicked && bmp_ready) begin
                scan_start_pulse      <= 1'b1;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                auto_cnt              <= 32'd0;
                img_found_count       <= 3'd0;
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
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
                if (key_next_press && scan_done && (img_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // 自动播放开/关（电平控制，来自 ctrl 的 o_auto_play）
                if (auto_play_level != auto_play_en)
                    auto_cnt <= 32'd0;
                auto_play_en <= auto_play_level;

                // 自动播放 1s 计数：只有当前没有写图任务时才计时
                if (scan_done && auto_play_en && display_valid && !load_busy && first_image_committed && (img_found_count > 3'd1)) begin
                    if (auto_tick)
                        auto_cnt <= 32'd0;
                    else
                        auto_cnt <= auto_cnt + 32'd1;
                end else begin
                    auto_cnt <= 32'd0;
                end

                // 首图自动加载到 buffer0（若首图坏则沿 fail 链继续尝试后续图片）
                if (scan_done && !first_image_committed && bmp_ready && !load_busy && (img_found_count != 3'd0)) begin
                    load_idx         <= fail_valid ? next_from_current : 3'd0;
                    load_sector      <= fail_valid ? sector_lut(next_from_current) : img_sector0;
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
                else if (scan_done && bmp_ready && display_valid && !load_busy && next_req_pending && (img_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
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
                else if (scan_done && bmp_ready && display_valid && !load_busy && auto_play_en && auto_tick && (img_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    load_sector      <= sector_lut(next_from_current);
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
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

    .load_start             (load_start_pulse),
    .load_abort             (load_abort),
    .load_sector            (load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code_i),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .write_req              (write_req),
    .write_req_ack          (write_req_ack),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .src_width              (src_width),
    .src_height             (src_height),
    .i_stall                (scale_almost_full)
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
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .sd_sec_write           (1'b0),
    .sd_sec_write_addr      (32'd0),
    .sd_sec_write_data      (),
    .sd_sec_write_data_req  (),
    .sd_sec_write_end       ()
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
