// ============================================================================
// brightness_contrast — 亮度/对比度实时调节（拨码开关控制）
//
// 插在 video_delay 输出像素流与 OSD 叠加层之间，对视频内容做亮度/对比度调整，
// OSD 文字在它之后生成，因此不受调节影响、始终醒目可读。
//
// 映射：拨码 SW1~SW4（拨上=1，拨下=0）
//   亮度档位   = sw[3:2]（SW4,SW3）：0=-32, 1=0, 2=+32, 3=+64
//   对比度档位 = sw[1:0]（SW2,SW1）：0=0.75, 1=0.875, 2=1.0, 3=1.125
//
// 算法（每通道，围绕中点 128）：
//   x   = in - 128
//   xc  = x * contrast            （contrast 用移位加减近似：x - x/4、x - x/8、x、x + x/8）
//   sum = xc + 128 + bright
//   out = clip(sum, 0, 255)
// ============================================================================
module brightness_contrast (
    input  wire [3:0]  i_sw,        // {SW4,SW3,SW2,SW1}
    input  wire [23:0] i_rgb,
    output wire [23:0] o_rgb
);
    wire [1:0] bright_sel   = i_sw[3:2];
    wire [1:0] contrast_sel = i_sw[1:0];

    reg signed [9:0] bright_off;
    always @(*) begin
        case (bright_sel)
            2'd0: bright_off = -10'sd32;
            2'd1: bright_off = 10'sd0;
            2'd2: bright_off = 10'sd32;
            default: bright_off = 10'sd64;
        endcase
    end

    wire [7:0] r_out, g_out, b_out;
    bc_channel u_r(.i_pix(i_rgb[23:16]), .i_sel(contrast_sel), .i_bright(bright_off), .o_pix(r_out));
    bc_channel u_g(.i_pix(i_rgb[15:8]),  .i_sel(contrast_sel), .i_bright(bright_off), .o_pix(g_out));
    bc_channel u_b(.i_pix(i_rgb[7:0]),   .i_sel(contrast_sel), .i_bright(bright_off), .o_pix(b_out));

    assign o_rgb = {r_out, g_out, b_out};
endmodule

// 单通道亮度/对比度（组合逻辑）
module bc_channel (
    input  wire [7:0] i_pix,
    input  wire [1:0] i_sel,             // 对比度档位
    input  wire signed [9:0] i_bright,   // 亮度偏移（有符号）
    output wire [7:0] o_pix
);
    wire signed [9:0] x = $signed({2'b00, i_pix}) - 10'sd128;

    reg signed [10:0] xc;
    always @(*) begin
        case (i_sel)
            2'd0: xc = x - (x >>> 2);        // 0.75
            2'd1: xc = x - (x >>> 3);        // 0.875
            2'd2: xc = x;                    // 1.0
            default: xc = x + (x >>> 3);     // 1.125
        endcase
    end

    wire signed [11:0] sum = xc + 12'sd128 + i_bright;
    assign o_pix = (sum < 0) ? 8'd0 : (sum > 255) ? 8'd255 : sum[7:0];
endmodule
