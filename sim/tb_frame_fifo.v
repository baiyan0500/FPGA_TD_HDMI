`timescale 1ns/1ps
// frame_fifo_write 判据回归：剩余帧长预计算后的 into_burst 行为
//  · 相位1：整帧已在 FIFO（40 字）→ 应恰好 5 个 8 字突发
//  · 相位2：边写边进（每次 +4，FIFO 不足 8 时补）→ 不得读空、总读字数=40
module tb_frame_fifo;

localparam integer BURST = 8;
localparam integer TOTAL = 40;

reg clk = 0;
reg rst = 1;
always #4 clk = ~clk;              // 125MHz

reg         Sdr_init_done = 0;
reg         App_rd_busy   = 0;
reg         write_req     = 0;
reg  [9:0]  write_len     = 10'd40;
reg  [9:0]  used          = 10'd0;
integer     add_val       = 0;

wire        write_req_ack;
wire        write_finish;
wire        fifo_aclr;
wire        App_wr_en;
wire        O_wr_busy;
wire [9:0]  App_wr_addr;

frame_fifo_write #(
    .MEM_DATA_BITS (32),
    .ADDR_BITS     (10),
    .BURST_BITS    (4),
    .BURST_SIZE    (BURST),
    .WRITE_V_FLIP  (0),
    .FRAME_WIDTH   (8),
    .FRAME_HEIGHT  (4)
) dut (
    .rst            (rst),
    .mem_clk        (clk),
    .Sdr_init_done  (Sdr_init_done),
    .Sdr_init_ref_vld (1'b0),
    .Sdr_busy       (1'b0),
    .App_rd_busy    (App_rd_busy),
    .O_wr_busy      (O_wr_busy),
    .App_wr_en      (App_wr_en),
    .App_wr_addr    (App_wr_addr),
    .write_req      (write_req),
    .write_req_ack  (write_req_ack),
    .write_finish   (write_finish),
    .write_addr_0   (10'd0),
    .write_addr_1   (10'd0),
    .write_addr_2   (10'd0),
    .write_addr_3   (10'd0),
    .write_addr_index (2'd0),
    .write_len      (write_len),
    .fifo_aclr      (fifo_aclr),
    .rdusedw        (used)
);

integer reads = 0;
integer underflows = 0;
integer finishes = 0;
integer errs = 0;

always @(posedge clk or posedge rst) begin
    if (rst)
        used <= 10'd0;
    else
        used <= used + add_val[9:0] - (App_wr_en ? 10'd1 : 10'd0);
end

always @(posedge clk) begin
    if (!rst && App_wr_en) begin
        if (used == 10'd0) begin
            underflows = underflows + 1;
            $display("ERR underflow at read %0d", reads);
        end
        reads = reads + 1;
    end
    if (!rst && write_finish)
        finishes = finishes + 1;
end

task run_frame;
    input integer prefilled;
    begin
        @(negedge clk);
        write_req = 1'b1;
        while (!write_req_ack) @(posedge clk);
        @(negedge clk);
        write_req = 1'b0;
    end
endtask

initial begin
    rst = 1;
    #100;
    @(negedge clk);
    rst = 0;
    Sdr_init_done = 1;

    // ---- 相位1：整帧预装 ----
    @(negedge clk);
    add_val = 40;
    @(negedge clk);
    add_val = 0;
    wait (used == 10'd40);
    run_frame(1);
    wait (finishes == 1);
    @(negedge clk);
    if (reads != TOTAL) begin
        errs = errs + 1;
        $display("ERR phase1 reads=%0d exp=%0d", reads, TOTAL);
    end else
        $display("phase1 reads=%0d underflows=%0d", reads, underflows);

    // ---- 相位2：流式补水 ----
    @(negedge clk);
    reads = 0;
    finishes = 0;
    fork
        run_frame(0);
        begin
            // 源端：已送 40 字，FIFO 水位 <=8 时每次补 4 字
            while ((reads + used) < TOTAL) begin
                @(negedge clk);
                if (used <= 10'd8 && (reads + used + 4) <= TOTAL)
                    add_val = 4;
                else
                    add_val = 0;
            end
            add_val = 0;
        end
    join
    wait (finishes == 1);
    @(negedge clk);
    if (reads != TOTAL) begin
        errs = errs + 1;
        $display("ERR phase2 reads=%0d exp=%0d", reads, TOTAL);
    end
    if (underflows != 0) begin
        errs = errs + 1;
        $display("ERR phase2 underflows=%0d", underflows);
    end
    if (errs == 0)
        $display("PASS frame_fifo reads1=40 reads2=%0d underflows=%0d", reads, underflows);
    else
        $display("FAIL frame_fifo errs=%0d", errs);
    $finish;
end

initial begin
    #200000;
    $display("TIMEOUT used=%0d reads=%0d req_ack=%b finish=%0d state=%0d",
             used, reads, write_req_ack, finishes, dut.state);
    $finish;
end

endmodule
