`timescale 1ns/1ps
// 验证 ctrl 三层按键映射（CLK_FREQ_HZ 参数固定 25MHz，TB 用快时钟压缩时间去抖）
module tb_ctrl;
    reg clk = 0, rst = 0;
    reg k1 = 1, k2 = 1, k3 = 1, k4 = 1;
    reg [3:0] sw = 4'b0001;

    wire [1:0] layer, mode, viz;
    wire [2:0] bright, contrast;
    wire       next_en, auto_play, aud_pause;
    wire       vplay, dmen, specen, rmen, warnen;

    ctrl dut(
        .i_clk(clk), .i_rst(rst),
        .i_k1(k1), .i_k2(k2), .i_k3(k3), .i_k4(k4), .i_sw(sw),
        .o_layer(layer), .o_mode(mode),
        .o_bright(bright), .o_contrast(contrast),
        .o_next_img_en(next_en), .o_auto_play(auto_play),
        .o_audio_pause(aud_pause), .o_viz_mode(viz),
        .o_video_play(vplay), .o_danmaku_en(dmen),
        .o_spectrum_en(specen), .o_resmon_en(rmen),
        .o_warn_en(warnen)
    );

    always #1 clk = ~clk;

    localparam integer HOLD = 600_000;
    integer errs = 0;

    task press(input integer which);
        begin
            case (which)
                1: k1 = 0;
                2: k2 = 0;
                3: k3 = 0;
                default: k4 = 0;
            endcase
            repeat (HOLD) @(posedge clk);
            k1 = 1; k2 = 1; k3 = 1; k4 = 1;
            repeat (HOLD) @(posedge clk);
        end
    endtask

    task chk(input [127:0] tag, input integer got, input integer exp);
        begin
            if (got !== exp) begin
                errs = errs + 1;
                $display("FAIL %0s: got %0d exp %0d", tag, got, exp);
            end else
                $display("ok   %0s = %0d", tag, got);
        end
    endtask

    initial begin
        rst = 1; #200 rst = 0; #100;

        // ---------------- 层1：SW1=1 ----------------
        sw = 4'b0001; #100;
        chk("L1 layer", layer, 1);
        chk("L1 next_en", next_en, 1);
        chk("L1 mode0", mode, 0);
        press(1); chk("L1 k1 mode", mode, 1);
        press(1); chk("L1 k1 mode", mode, 2);
        press(1); press(1); chk("L1 k1 wrap", mode, 0);
        chk("L1 bright init", bright, 4);
        press(3); chk("L1 k3 bright", bright, 0);     // 100% -> 20%
        press(3); chk("L1 k3 bright", bright, 1);
        press(4); chk("L1 k4 cont", contrast, 0);
        press(4); press(4); press(4); chk("L1 k4 cont", contrast, 3);
        press(4); chk("L1 k4 cont", contrast, 4);
        press(4); chk("L1 k4 wrap", contrast, 0);
        press(2); chk("L1 k2 no state", mode, 0);

        // ---------------- 层2：SW1=0 SW2=1 ----------------
        sw = 4'b0010; #100;
        chk("L2 layer", layer, 2);
        chk("L2 next_en", next_en, 0);
        chk("L2 auto init", auto_play, 0);
        press(2); chk("L2 k2 auto on", auto_play, 1);
        press(2); chk("L2 k2 auto off", auto_play, 0);
        chk("L2 aud init", aud_pause, 0);
        press(3); chk("L2 k3 pause", aud_pause, 1);
        press(3); chk("L2 k3 run", aud_pause, 0);
        chk("L2 viz init", viz, 0);
        press(4); chk("L2 k4 viz", viz, 1);
        press(4); chk("L2 k4 viz", viz, 2);
        press(4); chk("L2 k4 viz wrap", viz, 0);
        press(1); chk("L2 k1 mode", mode, 1);

        // ---------------- 层3：SW3=1 ----------------
        sw = 4'b0100; #100;
        chk("L3 layer", layer, 3);
        chk("L3 auto force off", auto_play, 0);
        chk("L3 viz force off", viz, 0);
        chk("L3 vplay init", vplay, 0);
        press(1); chk("L3 k1 play", vplay, 1);
        press(1); chk("L3 k1 stop", vplay, 0);
        chk("L3 dmen init", dmen, 1);
        press(2); chk("L3 k2 dmen", dmen, 0);
        press(2); chk("L3 k2 dmen", dmen, 1);
        chk("L3 spec init", specen, 0);
        press(3); chk("L3 k3 spec", specen, 1);
        press(3); chk("L3 k3 spec", specen, 0);
        chk("L3 rmen init", rmen, 0);
        press(4); chk("L3 k4 rmen", rmen, 1);
        press(4); chk("L3 k4 rmen", rmen, 0);

        // ---------------- 层0：全低 ----------------
        sw = 4'b0000; #100;
        chk("L0 layer", layer, 0);
        chk("L0 next_en", next_en, 0);
        press(1); chk("L0 k1 ignored", mode, 1);
        press(3); chk("L0 k3 ignored", specen, 0);

        // 层3 播放中切回层1：视频应停
        sw = 4'b0100; #100; press(1); chk("L3 play again", vplay, 1);
        sw = 4'b0001; #100;
        chk("L1 stops video", vplay, 0);
        chk("L1 layer", layer, 1);

        // ---------------- SW4：独立最高优先级告警使能 ----------------
        sw = 4'b1000; #100;
        chk("SW4 alone layer", layer, 0);
        chk("SW4 alone warn", warnen, 1);
        sw = 4'b1001; #100;
        chk("SW4+SW1 layer", layer, 1);
        chk("SW4+SW1 warn", warnen, 1);
        sw = 4'b0100; #100;
        chk("SW4 off warn", warnen, 0);

        if (errs == 0) $display("TB_CTRL PASS");
        else           $display("TB_CTRL FAIL %0d", errs);
        $finish;
    end
endmodule
