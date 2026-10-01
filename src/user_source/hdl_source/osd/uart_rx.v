// ============================================================================
// uart_rx — UART 接收（8N1）
// 复用官方例程逻辑，参数化时钟与波特率。
// 接收一个字节后，rx_done 产生一拍高脉冲，rx_data 为该字节。
// ============================================================================
module uart_rx #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire        clk,
    input  wire        rst_n,      // 低有效复位
    input  wire        rx,         // UART 接收端
    output reg         rx_done,
    output reg  [7:0]  rx_data
);
    localparam BAUD_CNT_MAX = CLK_FREQ / BAUD_RATE;

    reg        rx_d0, rx_d1, rx_d2;
    reg        rx_flag;
    reg  [3:0] rx_cnt;
    reg  [15:0] baud_cnt;
    reg  [7:0] rx_data_t;
    wire       start_en;

    assign start_en = rx_d2 & (~rx_d1) & (~rx_flag);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_d0 <= 1'b0; rx_d1 <= 1'b0; rx_d2 <= 1'b0;
        end else begin
            rx_d0 <= rx;
            rx_d1 <= rx_d0;
            rx_d2 <= rx_d1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_flag <= 1'b0;
        else if (start_en) rx_flag <= 1'b1;
        else if ((rx_cnt == 4'd9) && (baud_cnt == BAUD_CNT_MAX/2 - 1'b1)) rx_flag <= 1'b0;
        else rx_flag <= rx_flag;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) baud_cnt <= 16'd0;
        else if (rx_flag) begin
            if (baud_cnt < BAUD_CNT_MAX - 1'b1) baud_cnt <= baud_cnt + 16'b1;
            else baud_cnt <= 16'd0;
        end else baud_cnt <= 16'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_cnt <= 4'd0;
        else if (rx_flag) begin
            if (baud_cnt == BAUD_CNT_MAX - 1'b1) rx_cnt <= rx_cnt + 4'd1;
            else rx_cnt <= rx_cnt;
        end else rx_cnt <= 4'd0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rx_data_t <= 8'b0;
        else if (rx_flag) begin
            if (baud_cnt == BAUD_CNT_MAX/2 - 1'b1) begin
                case (rx_cnt)
                    4'd1: rx_data_t[0] <= rx_d2;
                    4'd2: rx_data_t[1] <= rx_d2;
                    4'd3: rx_data_t[2] <= rx_d2;
                    4'd4: rx_data_t[3] <= rx_d2;
                    4'd5: rx_data_t[4] <= rx_d2;
                    4'd6: rx_data_t[5] <= rx_d2;
                    4'd7: rx_data_t[6] <= rx_d2;
                    4'd8: rx_data_t[7] <= rx_d2;
                    default: ;
                endcase
            end
        end else rx_data_t <= 8'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_done  <= 1'b0;
            rx_data  <= 8'b0;
        end else if (rx_cnt == 4'd9 && baud_cnt == BAUD_CNT_MAX/2 - 1'b1) begin
            rx_done <= 1'b1;
            rx_data <= rx_data_t;
        end else begin
            rx_done <= 1'b0;
            rx_data <= rx_data;
        end
    end
endmodule
