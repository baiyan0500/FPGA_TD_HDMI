`timescale 1ns/1ps
// 验证 scaler：320×240 → 640×480，输出 307200 像素（带超时保护）
module tb_scaler;
    reg clk = 0, rst = 0, start = 0;
    reg [15:0] src_w = 320, src_h = 240;
    reg src_en = 0;
    reg [23:0] src_data = 0;
    wire dst_en;
    wire [23:0] dst_data;
    wire done;
    wire almost_full;
    integer dst_cnt = 0;
    integer wr_cnt = 0;
    integer rd_cnt = 0;

    scaler dut(.clk(clk), .rst(rst), .start(start), .src_w(src_w), .src_h(src_h),
               .src_en(src_en), .src_data(src_data), .almost_full(almost_full),
               .dst_en(dst_en), .dst_data(dst_data), .done(done));

    always #10 clk = ~clk;

    integer i, j, pix;
    initial begin
        rst = 1; #30 rst = 0; #20;
        start = 1; #20 start = 0;
        // 真实链路里首个像素要等 SD 读回一个扇区（~164µs）才到；
        // start 同拍就喂数据会被 start_edge 的 FIFO 清空吃掉首像素
        repeat (8) @(posedge clk);
        pix = 0;
        for (j = 0; j < 240; j = j + 1) begin
            for (i = 0; i < 320; i = i + 1) begin
                while (almost_full) @(posedge clk);   // 背压等待
                src_en = 1; src_data = pix; pix = pix + 1; wr_cnt = wr_cnt + 1; @(posedge clk);
                src_en = 0; @(posedge clk); @(posedge clk);
            end
        end
        src_en = 0;
    end

    always @(posedge clk) if (dst_en) dst_cnt <= dst_cnt + 1;

    // 超时观察
    initial begin
        #30000000;
        $display("TIMEOUT: dst_cnt=%0d wr_cnt=%0d rd_cnt=%0d state=%0d fifo_cnt=%0d",
                 dst_cnt, wr_cnt, rd_cnt, dut.state, dut.fifo_cnt);
        $display("  src_w_l=%0d src_h_l=%0d dst_y=%0d y_acc=%0d dst_x=%0d rd_x=%0d",
                 dut.src_w_l, dut.src_h_l, dut.dst_y, dut.y_acc, dut.dst_x, dut.rd_x);
        $finish;
    end

    // done 观察
    always @(posedge done) begin
        $display("DONE: dst_cnt=%0d state=%0d", dst_cnt, dut.state);
        $finish;
    end
endmodule
