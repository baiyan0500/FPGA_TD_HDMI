// ============================================================================
// slogan_ctrl — 上位机标语接收与解析
//
// 接收 uart_rx 的字节流，按行（\n 或 \r 结尾）解析：
//   "left"  → 滚动方向 = 从右向左（dir=0）
//   "right" → 滚动方向 = 从左往右（dir=1）
//   其他文本 → 更新标语内容（最多 32 字符），并翻转 o_update 通知显示层
//
// 默认标语 "EG4S20 HDMI PLAYER"（18 字符）。
// 时钟域：clk 50MHz（与 uart_rx 同域）。标语内容/长度/方向由 o_update toggle
// 握手跨到 video_clk 域，供 osd_layer 锁存。
// ============================================================================
module slogan_ctrl (
    input  wire         clk,
    input  wire         rst,           // 高有效复位
    input  wire         rx_done,
    input  wire [7:0]   rx_data,
    output wire [255:0] o_slogan,      // 32 字节标语内容（打包，slogan[0] 在最高字节）
    output wire [5:0]   o_len,         // 标语长度 0~32
    output wire         o_dir,         // 0=从右向左, 1=从左往右
    output reg          o_update,      // 更新 toggle（内容变化时翻转）
    output reg          o_scroll_en    // 滚动使能（过长自动滚 或 收到方向命令后强制滚）
);
    reg [7:0] tmp    [0:31];
    reg [7:0] slogan [0:31];
    reg [5:0] tmp_len;
    reg [5:0] slogan_len;
    reg       dir;

    // 打包输出
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : pack
            assign o_slogan[ (31-g)*8 +: 8 ] = slogan[g];
        end
    endgenerate
    assign o_len = slogan_len;
    assign o_dir = dir;

    // 行解析辅助
    wire is_left  = (tmp_len == 6'd4) && (tmp[0] == 8'h6C) && (tmp[1] == 8'h65) && (tmp[2] == 8'h66) && (tmp[3] == 8'h74);
    wire is_right = (tmp_len == 6'd5) && (tmp[0] == 8'h72) && (tmp[1] == 8'h69) && (tmp[2] == 8'h67) && (tmp[3] == 8'h68) && (tmp[4] == 8'h74);

    integer i;
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            tmp_len    <= 6'd0;
            slogan_len <= 6'd18;
            dir        <= 1'b0;
            o_update   <= 1'b0;
            o_scroll_en <= 1'b0;
            // 默认标语 "EG4S20 HDMI PLAYER"
            slogan[0]  <= "E"; slogan[1]  <= "G"; slogan[2]  <= "4"; slogan[3]  <= "S";
            slogan[4]  <= "2"; slogan[5]  <= "0"; slogan[6]  <= " "; slogan[7]  <= "H";
            slogan[8]  <= "D"; slogan[9]  <= "M"; slogan[10] <= "I"; slogan[11] <= " ";
            slogan[12] <= "P"; slogan[13] <= "L"; slogan[14] <= "A"; slogan[15] <= "Y";
            slogan[16] <= "E"; slogan[17] <= "R";
            for (i = 0; i < 32; i = i + 1) tmp[i] <= 8'h00;
        end else if (rx_done) begin
            if (rx_data == 8'h0A || rx_data == 8'h0D) begin
                // 行结束：解析
                if (is_left) begin
                    dir <= 1'b0;
                    o_update <= ~o_update;
                    o_scroll_en <= 1'b1;
                end else if (is_right) begin
                    dir <= 1'b1;
                    o_update <= ~o_update;
                    o_scroll_en <= 1'b1;
                end else if (tmp_len > 6'd0) begin
                    // 更新标语内容
                    slogan_len <= tmp_len;
                    for (i = 0; i < 32; i = i + 1) slogan[i] <= tmp[i];
                    o_update <= ~o_update;
                    o_scroll_en <= (tmp_len > 6'd31);
                end
                tmp_len <= 6'd0;
                for (i = 0; i < 32; i = i + 1) tmp[i] <= 8'h00;
            end else begin
                // 累积字节（截断到 32）
                if (tmp_len < 6'd32) begin
                    tmp[tmp_len] <= rx_data;
                    tmp_len <= tmp_len + 6'd1;
                end
            end
        end
    end
endmodule
