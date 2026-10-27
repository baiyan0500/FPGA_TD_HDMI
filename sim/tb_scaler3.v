`timescale 1ns/1ps
// 验证 scaler 640×480 原样：输出像素值顺序 = 输入（1:1）
module tb_scaler3;
    reg clk = 0, rst = 0, start = 0;
    reg [15:0] src_w = 640, src_h = 480;
    reg src_en = 0;
    reg [23:0] src_data = 0;
    wire dst_en;
    wire [23:0] dst_data;
    wire done;
    integer dst_cnt = 0;
    integer mism = 0;
    reg [23:0] expect = 0;

    scaler dut(.clk(clk), .rst(rst), .start(start), .src_w(src_w), .src_h(src_h),
               .src_en(src_en), .src_data(src_data), .dst_en(dst_en), .dst_data(dst_data), .done(done));

    always #10 clk = ~clk;

    integer i, j;
    reg [23:0] pix;
    initial begin
        rst = 1; #30 rst = 0; #20;
        start = 1; #20 start = 0;
        // 真实链路里首个像素要等 SD 读回一个扇区（~164µs）才到；
        // start 同拍就喂数据会被 start_edge 的 FIFO 清空吃掉首像素
        repeat (8) @(posedge clk);
        pix = 0;
        for (j = 0; j < 480; j = j + 1) begin
            for (i = 0; i < 640; i = i + 1) begin
                while (dut.almost_full) @(posedge clk);
                src_en = 1; src_data = pix; pix = pix + 1; @(posedge clk);
                src_en = 0; @(posedge clk); @(posedge clk);
            end
        end
        src_en = 0;
    end

    // 检查 dst 输出顺序
    always @(posedge clk) begin
        if (dst_en) begin
            dst_cnt <= dst_cnt + 1;
            if (dst_data !== expect) mism <= mism + 1;
            expect <= expect + 1;
        end
    end
    always @(posedge done) begin
        $display("DONE: dst_cnt=%0d mism=%0d", dst_cnt, mism);
        $finish;
    end

    initial begin
        #40000000;
        $display("TIMEOUT: dst_cnt=%0d mism=%0d state=%0d", dst_cnt, mism, dut.state);
        $finish;
    end
endmodule
