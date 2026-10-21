// ============================================================================
// scaler — 最近邻缩放（任意分辨率 → 640×480），显式同步读时序
//
// 插在 bmp_read 与写 FIFO 之间（sd_card_clk 域）。把任意 src_w×src_h 的像素流
// 缩放到 640×480。输入 FIFO 缓冲源像素（解耦 SD 读速率），行缓存存一行源图，
// 配合水平/垂直 DDA 实现最近邻。
//
// 关键：line_buf / fifo_mem 一律用「同步读」（读地址打一拍、读数据打一拍），
// 不依赖综合器对 RAM 的推断（无论综合成 BRAM 还是 LUT，时序都一致），
// 避免「仿真组合读通过、上板 BRAM 同步读错位」的问题。
// ============================================================================
module scaler #(
    parameter DST_W      = 640,
    parameter DST_H      = 480,
    parameter SRC_MAX    = 1024,
    parameter FIFO_DEPTH = 512
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [15:0]  src_w,
    input  wire [15:0]  src_h,
    input  wire         src_en,
    input  wire [23:0]  src_data,
    output wire         almost_full,
    output reg          dst_en,
    output reg  [23:0]  dst_data,
    output reg          done
);
    // start 边沿检测（write_req_ack 是 mem_clk 域持续电平，2 级同步后取上升沿）
    reg  start_s1, start_s2;
    wire start_edge = start_s1 & ~start_s2;
    always @(posedge clk or posedge rst) begin
        if (rst) begin start_s1 <= 1'b0; start_s2 <= 1'b0; end
        else begin start_s1 <= start; start_s2 <= start_s1; end
    end

    // ---- 输入 FIFO ----
    // 强制 block_ram：512x24 = 12kbit，LUT RAM 实现会吃掉 ~1.5k LUT 加剧布线拥塞
    (* ramstyle = "block_ram", ram_style = "block_ram" *) reg [23:0] fifo_mem [0:FIFO_DEPTH-1];
    reg [8:0]  fifo_wptr, fifo_rptr;
    reg [9:0]  fifo_cnt;
    wire       fifo_wr    = src_en && (fifo_cnt < FIFO_DEPTH);
    wire       fifo_empty = (fifo_cnt == 10'd0);
    assign     almost_full = (fifo_cnt > (FIFO_DEPTH - 180));
    reg [23:0] fifo_dout_r;      // fifo 同步读数据

    // ---- 行缓存 ----
    // 1024x24 显式例化 BRAM9K 原语：综合器对该深度拒绝 block_ram 推断
    // （SYN-1027 仍推成 DRAM 吃掉 ~3k LUT，导致 x7y2 布线冲突）
    // NOREG 模式读延迟 1 拍，与原 "lbuf_dout_r <= line_buf[rd_x]" 时序完全一致
    wire [23:0] lbuf_dout_r;     // BRAM B 口同步读数据（地址给出后下一拍有效）

    localparam S_IDLE      = 3'd0;
    localparam S_READ_ADDR = 3'd1;
    localparam S_READ_DATA = 3'd2;
    localparam S_OUT_ADDR  = 3'd3;
    localparam S_OUT_DATA  = 3'd4;
    localparam S_DONE      = 3'd5;

    reg [2:0]  state;
    reg [10:0] src_w_l, src_h_l;
    reg [10:0] wr_x, rd_x;
    reg [10:0] dst_x, dst_y;
    reg [11:0] x_acc, y_acc;
    reg        skip_cnt;

    // 水平 DDA（最多减 2 次）
    wire [11:0] xa1 = x_acc + {1'b0, src_w_l};
    wire        x_ov1 = (xa1 >= 12'd640);
    wire [11:0] xa2 = xa1 - 12'd640;
    wire        x_ov2 = (xa2 >= 12'd640);
    wire [11:0] x_acc_next = x_ov1 ? (x_ov2 ? (xa2 - 12'd640) : xa2) : xa1;
    wire [1:0]  rd_inc = (x_ov1 ? 2'd1 : 2'd0) + (x_ov2 ? 2'd1 : 2'd0);

    // 垂直 DDA（最多减 2 次）
    wire [11:0] ya1 = y_acc + {1'b0, src_h_l};
    wire        y_ov1 = (ya1 >= 12'd480);
    wire [11:0] ya2 = ya1 - 12'd480;
    wire        y_ov2 = (ya2 >= 12'd480);
    wire [11:0] y_acc_next = y_ov1 ? (y_ov2 ? (ya2 - 12'd480) : ya2) : ya1;

    // ---- FIFO 写 ----
    always @(posedge clk or posedge rst) begin
        if (rst) fifo_wptr <= 9'd0;
        else if (fifo_wr) begin
            fifo_mem[fifo_wptr] <= src_data;
            fifo_wptr <= fifo_wptr + 9'd1;
        end
    end

    // ---- FIFO 同步读 ----
    always @(posedge clk or posedge rst) begin
        if (rst) fifo_dout_r <= 24'd0;
        else if (state == S_READ_ADDR && !fifo_empty)
            fifo_dout_r <= fifo_mem[fifo_rptr];
    end

    // ---- line_buf BRAM 例化（A 口写 / B 口读，单时钟伪双口）----
    // 写：S_READ_DATA 状态每拍写入 fifo_dout_r；读：S_OUT_ADDR 拍给出 rd_x，
    // 下一拍（S_OUT_DATA）dob 有效，时序与原同步读完全一致
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(24), .ADDR_WIDTH_A(10),
        .DATA_WIDTH_B(24), .ADDR_WIDTH_B(10),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_line_buf (
        .dia(fifo_dout_r), .addra(wr_x[9:0]), .cea(1'b1), .ocea(1'b1),
        .clka(clk), .wea(state == S_READ_DATA), .rsta(1'b0), .bea(1'b1),
        .dib(24'd0), .addrb(rd_x[9:0]), .ceb(1'b1), .oceb(1'b1),
        .clkb(clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lbuf_dout_r)
    );

    // ---- FIFO 读指针 + 计数 ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            fifo_rptr <= 9'd0;
            fifo_cnt  <= 10'd0;
        end else begin
            if (state == S_READ_ADDR && !fifo_empty)
                fifo_rptr <= fifo_rptr + 9'd1;
            case ({fifo_wr, (state == S_READ_ADDR && !fifo_empty)})
                2'b10:   fifo_cnt <= fifo_cnt + 10'd1;
                2'b01:   fifo_cnt <= fifo_cnt - 10'd1;
                default: fifo_cnt <= fifo_cnt;
            endcase
        end
    end

    // ---- 主状态机 ----
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state    <= S_IDLE;
            dst_en   <= 1'b0;
            dst_data <= 24'd0;
            done     <= 1'b0;
            src_w_l  <= 11'd0; src_h_l <= 11'd0;
            wr_x     <= 11'd0; rd_x <= 11'd0;
            dst_x    <= 11'd0; dst_y <= 11'd0;
            x_acc    <= 12'd0; y_acc <= 12'd0;
            skip_cnt <= 1'b0;
        end else begin
            dst_en <= 1'b0;
            done   <= 1'b0;
            if (start_edge) begin
                // 任意状态下收到 start 都强制重启（防止上一帧卡死导致后续无法恢复）
                src_w_l  <= (src_w[10:0] == 11'd0) ? 11'd1 : src_w[10:0];
                src_h_l  <= (src_h[10:0] == 11'd0) ? 11'd1 : src_h[10:0];
                wr_x     <= 11'd0;
                dst_y    <= 11'd0;
                y_acc    <= 12'd0;
                skip_cnt <= 1'b0;
                state    <= S_READ_ADDR;
            end else begin
                case (state)
                S_IDLE: begin
                end
                S_READ_ADDR: begin
                    // 提供 fifo 读地址（同步读，下一拍 fifo_dout_r 有效）
                    if (!fifo_empty)
                        state <= S_READ_DATA;
                end
                S_READ_DATA: begin
                    // 数据有效：写 line_buf（BRAM A 口 wea = state==S_READ_DATA 自动完成）
                    wr_x <= wr_x + 11'd1;
                    if (wr_x == src_w_l - 11'd1) begin
                        wr_x <= 11'd0;
                        if (skip_cnt) begin
                            skip_cnt <= 1'b0;   // 跳过这一行，重新读
                            state    <= S_READ_ADDR;
                        end else begin
                            rd_x  <= 11'd0;
                            dst_x <= 11'd0;
                            x_acc <= 12'd0;
                            state <= S_OUT_ADDR;
                        end
                    end else begin
                        state <= S_READ_ADDR;
                    end
                end
                S_OUT_ADDR: begin
                    // 提供 line_buf 读地址（同步读），更新 DDA
                    rd_x  <= rd_x + {9'd0, rd_inc};
                    x_acc <= x_acc_next;
                    state <= S_OUT_DATA;
                end
                S_OUT_DATA: begin
                    // 数据有效：输出 dst
                    dst_data <= lbuf_dout_r;
                    dst_en   <= 1'b1;
                    dst_x    <= dst_x + 11'd1;
                    if (dst_x == DST_W - 11'd1) begin
                        dst_y <= dst_y + 11'd1;
                        y_acc <= y_acc_next;
                        if (y_ov1) begin
                            if (dst_y == DST_H - 11'd1) begin
                                state <= S_DONE;
                            end else begin
                                wr_x     <= 11'd0;
                                skip_cnt <= y_ov2;
                                state    <= S_READ_ADDR;
                            end
                        end else begin
                            rd_x  <= 11'd0;
                            dst_x <= 11'd0;
                            x_acc <= 12'd0;
                            state <= S_OUT_ADDR;
                        end
                    end else begin
                        state <= S_OUT_ADDR;
                    end
                end
                S_DONE: begin
                    done  <= 1'b1;
                    state <= S_IDLE;
                end
                default: state <= S_IDLE;
                endcase
            end
        end
    end
endmodule
