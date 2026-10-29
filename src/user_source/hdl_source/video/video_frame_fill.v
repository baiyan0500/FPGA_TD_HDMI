// ============================================================================
// video_frame_fill — RGB565 像素流 → 640x480 居中 2 倍放大 → SDRAM 帧写口
//
// SW3 视频层专用。EGV 帧为 320x148 RGB565，本模块把每个源行展开成两行、
// 每个像素横向复制两次，居中放进 640x480 帧的 92..387 行；
// 上下各 92 行黑边在首次进入视频模式时一次性初始化，之后每帧只重写中间
// 296 行（write_len = 296*640），既省带宽，也避开"黑边必须排在数据流前面"
// 导致的行缓冲溢出问题。
//
// 行缓冲：4 个 512x16 BRAM（仅用 320 深度）。源行 r 写 bank r[1:0]，
//         输出端读同一 bank；4 bank 保证写端不会覆盖正在读的行。
//
// 时序：写口 4 拍一字（25M 字/s = 100MB/s），远低于 SDRAM 上限；
//       一帧 296 行约 11.4ms，远小于 41.7ms 帧周期。
// ============================================================================
`timescale 1ns/1ps

module video_frame_fill #(
    parameter integer SRC_W       = 320,
    parameter integer SRC_H       = 148,
    parameter [20:0]  FULL_WORDS  = 21'd307_200,           // 640*480
    parameter [20:0]  VIDEO_WORDS = 21'd189_440            // 296*640
)(
    input  wire        clk,           // sd_card_clk 100MHz
    input  wire        rst,
    input  wire        i_en,          // 视频模式

    // 源像素流
    input  wire        i_frame_start,
    input  wire        i_pix_en,
    input  wire [15:0] i_pix,

    // SDRAM 帧写口（frame_read_write）
    output reg         o_wr_req,
    input  wire        i_wr_ack,
    output reg         o_wr_en,
    output reg  [31:0] o_wr_data,
    output reg  [20:0] o_wr_len,
    output reg         o_wr_bank,     // 0 -> BUF2, 1 -> BUF3
    output reg         o_addr_full,   // 1 -> 写满帧（初始化），0 -> 只写中间 296 行
    input  wire        i_fin_tgl,     // ext_mem_clk 域帧写完成 toggle

    output reg         o_disp_bank,   // 显示缓冲（读侧）
    output reg         o_ready,       // 初始化完成，可以显示视频
    output wire        o_busy,
    output reg         o_frame_end
);

    // ------------------------------------------------------------------
    // 行缓冲：4 x 512x16（仅用 320 深度）
    // ------------------------------------------------------------------
    reg [8:0]  f_row;            // 正在写的源行 0..SRC_H
    reg [8:0]  f_col;            // 0..SRC_W-1
    wire [1:0] f_bank = f_row[1:0];
    wire       f_we   = i_pix_en && (f_row < SRC_H);

    reg  [8:0] e_row;            // 正在输出的源行
    reg  [8:0] p;                // 源列
    reg        phase;            // 0=上半行 1=下半行
    wire [1:0] e_bank = e_row[1:0];

    wire [15:0] lb0_dob, lb1_dob, lb2_dob, lb3_dob;
    reg  [15:0] lb_dout;

    always @(*) begin
        case (e_bank)
            2'd0:    lb_dout = lb0_dob;
            2'd1:    lb_dout = lb1_dob;
            2'd2:    lb_dout = lb2_dob;
            default: lb_dout = lb3_dob;
        endcase
    end

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(9), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(9),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_lb0 (
        .dia(i_pix), .addra(f_col), .cea(1'b1), .ocea(1'b1),
        .clka(clk), .wea(f_we && (f_bank == 2'd0)), .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(p), .ceb(1'b1), .oceb(1'b1),
        .clkb(clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb0_dob)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(9), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(9),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_lb1 (
        .dia(i_pix), .addra(f_col), .cea(1'b1), .ocea(1'b1),
        .clka(clk), .wea(f_we && (f_bank == 2'd1)), .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(p), .ceb(1'b1), .oceb(1'b1),
        .clkb(clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb1_dob)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(9), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(9),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_lb2 (
        .dia(i_pix), .addra(f_col), .cea(1'b1), .ocea(1'b1),
        .clka(clk), .wea(f_we && (f_bank == 2'd2)), .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(p), .ceb(1'b1), .oceb(1'b1),
        .clkb(clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb2_dob)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(9), .DATA_WIDTH_B(16), .ADDR_WIDTH_B(9),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K")
    ) u_lb3 (
        .dia(i_pix), .addra(f_col), .cea(1'b1), .ocea(1'b1),
        .clka(clk), .wea(f_we && (f_bank == 2'd3)), .rsta(1'b0), .bea(1'b1),
        .dib(16'd0), .addrb(p), .ceb(1'b1), .oceb(1'b1),
        .clkb(clk), .web(1'b0), .rstb(1'b0), .beb(1'b1),
        .doa(), .dob(lb3_dob)
    );

    // RGB565 -> RGB888（高位复制）
    wire [23:0] pix888 = {lb_dout[15:11], lb_dout[13:11],
                          lb_dout[10:5],  lb_dout[9:8],
                          lb_dout[4:0],   lb_dout[2:0]};

    // ------------------------------------------------------------------
    // 写节拍：4 拍一个字
    // ------------------------------------------------------------------
    reg [1:0] pac;
    wire      step = (pac == 2'd3);
    always @(posedge clk or posedge rst) begin
        if (rst) pac <= 2'd0;
        else     pac <= pac + 2'd1;
    end

    // ------------------------------------------------------------------
    // 帧写完成 toggle 同步（ext_mem_clk 125MHz -> 100MHz）
    // ------------------------------------------------------------------
    reg [2:0] fin_s;
    always @(posedge clk or posedge rst) begin
        if (rst) fin_s <= 3'b000;
        else     fin_s <= {fin_s[1:0], i_fin_tgl};
    end
    wire fin_edge = fin_s[2] ^ fin_s[1];

    // ------------------------------------------------------------------
    // 主状态机
    // ------------------------------------------------------------------
    localparam [3:0] E_OFF    = 4'd0,
                     E_I_REQ  = 4'd1,
                     E_I_WAIT = 4'd2,
                     E_I_DATA = 4'd3,
                     E_IDLE   = 4'd4,
                     E_ACK    = 4'd5,
                     E_ROWW   = 4'd6,
                     E_RD     = 4'd7,
                     E_W0     = 4'd8,
                     E_W1     = 4'd9,
                     E_END    = 4'd10;

    reg [3:0]  st;
    reg        init_phase;
    reg [20:0] zcnt;

    assign o_busy = (st != E_OFF) && (st != E_IDLE);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st          <= E_OFF;
            o_wr_req    <= 1'b0;
            o_wr_en     <= 1'b0;
            o_wr_data   <= 32'd0;
            o_wr_len    <= FULL_WORDS;
            o_wr_bank   <= 1'b0;
            o_addr_full <= 1'b1;
            o_disp_bank <= 1'b0;
            o_ready     <= 1'b0;
            o_frame_end <= 1'b0;
            init_phase  <= 1'b0;
            zcnt        <= 21'd0;
            f_row       <= 9'd0;
            f_col       <= 9'd0;
            e_row       <= 9'd0;
            p           <= 9'd0;
            phase       <= 1'b0;
        end else begin
            o_wr_en     <= 1'b0;
            o_frame_end <= 1'b0;

            // ---- 行缓冲填充 ----
            if (i_pix_en && (f_row < SRC_H)) begin
                if (f_col == SRC_W[8:0] - 9'd1) begin
                    f_col <= 9'd0;
                    f_row <= f_row + 9'd1;
                end else
                    f_col <= f_col + 9'd1;
            end

            // ---- 显示缓冲切换（帧真正写进 SDRAM 后）----
            if (fin_edge && o_ready) begin
                o_disp_bank <= o_wr_bank;
                o_frame_end <= 1'b1;
            end

            case (st)
            // -------------------------------------------------- 初始化黑场
            E_OFF: begin
                o_wr_req <= 1'b0;
                if (i_en) begin
                    if (o_ready)
                        st <= E_IDLE;          // 黑边已初始化过，直接进帧循环
                    else begin
                        init_phase  <= 1'b0;
                        o_wr_bank   <= 1'b0;
                        o_wr_len    <= FULL_WORDS;
                        o_addr_full <= 1'b1;
                        st          <= E_I_REQ;
                    end
                end
            end
            E_I_REQ: begin
                o_wr_req <= 1'b1;
                zcnt     <= 21'd0;
                st       <= E_I_WAIT;
            end
            E_I_WAIT: begin
                if (i_wr_ack) begin
                    o_wr_req <= 1'b0;
                    zcnt     <= 21'd0;
                    st       <= E_I_DATA;
                end
            end
            E_I_DATA: begin
                if (step) begin
                    o_wr_en   <= 1'b1;
                    o_wr_data <= 32'd0;
                    if (zcnt == FULL_WORDS - 21'd1) begin
                        zcnt <= 21'd0;
                        if (init_phase) begin
                            st      <= E_IDLE;
                            o_ready <= 1'b1;
                        end else begin
                            init_phase <= 1'b1;
                            o_wr_bank  <= 1'b1;
                            st         <= E_I_REQ;
                        end
                    end else
                        zcnt <= zcnt + 21'd1;
                end
            end
            // -------------------------------------------------- 视频帧
            E_IDLE: begin
                if (!i_en) begin
                    st <= E_OFF;
                end else if (i_frame_start) begin
                    f_row <= 9'd0;
                    f_col <= 9'd0;
                    e_row <= 9'd0;
                    p     <= 9'd0;
                    phase <= 1'b0;
                    o_wr_bank   <= ~o_disp_bank;
                    o_wr_len    <= VIDEO_WORDS;
                    o_addr_full <= 1'b0;
                    o_wr_req    <= 1'b1;
                    st          <= E_ACK;
                end
            end
            E_ACK: begin
                if (i_wr_ack) begin
                    o_wr_req <= 1'b0;
                    st       <= E_ROWW;
                end
            end
            E_ROWW: begin
                if (f_row > e_row)
                    st <= E_RD;
            end
            E_RD: begin
                st <= E_W0;
            end
            E_W0: begin
                o_wr_en   <= 1'b1;
                o_wr_data <= {pix888, 8'h00};
                st        <= E_W1;
            end
            E_W1: begin
                o_wr_en   <= 1'b1;
                o_wr_data <= {pix888, 8'h00};
                if (p == SRC_W[8:0] - 9'd1) begin
                    p <= 9'd0;
                    if (!phase) begin
                        phase <= 1'b1;
                        st    <= E_RD;
                    end else begin
                        phase <= 1'b0;
                        e_row <= e_row + 9'd1;
                        if (e_row == SRC_H[8:0] - 9'd1)
                            st <= E_END;
                        else
                            st <= E_ROWW;
                    end
                end else begin
                    p  <= p + 9'd1;
                    st <= E_RD;
                end
            end
            E_END: begin
                st <= E_IDLE;
            end
            default: st <= E_OFF;
            endcase
        end
    end

endmodule
