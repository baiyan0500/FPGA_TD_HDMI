`timescale 1ns/1ps
// 验证 wr_fin_split：写完成按"应答时锁存的归属"分流
//   A) BMP 写完成 → 只翻 o_bmp_tgl
//   B) 视频写完成 → 只翻 o_vf_tgl
//   C) 视频写应答后归属提前掉 0（层被关）→ 仍算视频，o_vf_tgl 翻
//   D) 连续 BMP/视频交错 → 两路计数各自正确
module tb_wr_fin_split;
    reg clk = 0, rst = 1;
    reg owner = 0, ack = 0, finish = 0;
    wire vf_tgl, bmp_tgl;

    wr_fin_split dut(
        .clk(clk), .rst(rst),
        .i_owner(owner), .i_wr_ack(ack), .i_wr_finish(finish),
        .o_vf_tgl(vf_tgl), .o_bmp_tgl(bmp_tgl)
    );

    always #5 clk = ~clk;

    integer errs = 0;
    integer vf_n = 0, bmp_n = 0;

    // 监视 toggle 翻转次数（下降沿采样，避开与 posedge 的竞争）
    reg vf_q = 0, bmp_q = 0;
    always @(negedge clk) begin
        if (!rst) begin
            if (vf_tgl !== vf_q)  begin vf_n  = vf_n + 1;  vf_q  = vf_tgl;  end
            if (bmp_tgl !== bmp_q) begin bmp_n = bmp_n + 1; bmp_q = bmp_tgl; end
        end
    end

    task do_write;
        input       own;
        input       drop_before_finish;
        begin
            owner = own;
            repeat (4) @(posedge clk);      // 归属同步 2 级后再应答
            ack = 1; @(posedge clk); ack = 0;
            if (drop_before_finish)
                owner = ~own;               // 应答后归属翻转，不应影响本次归类
            repeat (3) @(posedge clk);
            finish = 1; @(posedge clk); finish = 0;
            repeat (2) @(posedge clk);
        end
    endtask

    task expect_cnt;
        input integer ev, eb;
        begin
            if (vf_n !== ev || bmp_n !== eb) begin
                $display("FAIL: vf=%0d (exp %0d) bmp=%0d (exp %0d)", vf_n, ev, bmp_n, eb);
                errs = errs + 1;
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        repeat (3) @(posedge clk);

        // A) BMP 写
        do_write(1'b0, 1'b0);
        expect_cnt(0, 1);

        // B) 视频写
        do_write(1'b1, 1'b0);
        expect_cnt(1, 1);

        // C) 视频应答后归属掉 0
        do_write(1'b1, 1'b1);
        expect_cnt(2, 1);

        // D) 交错：BMP → 视频 → BMP
        do_write(1'b0, 1'b0);
        do_write(1'b1, 1'b0);
        do_write(1'b0, 1'b0);
        expect_cnt(3, 3);

        // 归属掉 0 的 BMP 写（反方向）
        do_write(1'b0, 1'b1);
        expect_cnt(3, 4);

        if (errs == 0) $display("TB_WR_FIN_SPLIT PASS");
        else           $display("TB_WR_FIN_SPLIT FAIL (%0d)", errs);
        $finish;
    end

    initial begin
        #100_000;
        $display("TB_WR_FIN_SPLIT TIMEOUT");
        $finish;
    end
endmodule
