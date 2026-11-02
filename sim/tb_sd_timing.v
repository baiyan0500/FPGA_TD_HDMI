// ============================================================================
// tb_sd_timing — sd_card_top 读吞吐与数据正确性验证（SPI 卡模型）
//
// 覆盖：
//   · 初始化 CMD0/8/55/41/16（R1 轮询）
//   · 单扇区读 CMD17（每扇区一条命令）
//   · 多扇区流式读 CMD18（一条命令连续读 N 扇区，CS 抬升结束）
//   · 逐字节校验数据：扇区 s 的第 i 字节 = (addr + i) & 0xFF
//
// SPI 时序（本 DUT 为模式 3）：master 在下降沿换 MOSI、上升沿采 MISO；
// 卡模型相应地在上升沿采 MOSI、下降沿换 MISO。字节边界用 CS 下降沿对齐。
//
// 参数：
//   +N=<n>     每个测试的扇区数（默认 64）
//   +LAT=<n>   token 前插入的哑字节数（模拟卡内读延迟，默认 40）
//   +LAG=<n>  客户端地址更新相对 sec_end 的滞后拍数（默认 1 = 等价 bmp_read，
//             其结束脉冲多一级 bmp_e_q；0 = 理想客户端）
//   +DROP=<n>  非 0 时再叠加 ST_SCAN 式的"结束当拍撤一拍 sd_sec_read"
//   +DBG=<n>   1 打印收发字节，2 打印每次命令
// ============================================================================
`timescale 1ns/1ps

module tb_sd_timing;

    reg  clk = 1'b0;
    reg  rst = 1'b1;
    always #5 clk = ~clk;           // 100MHz

    reg  [31:0] sec_addr = 32'd0;
    reg  [15:0] sec_count = 16'd1;
    reg         rd_window = 1'b0;         // 测试窗口：允许持续读
    reg         cli_drop  = 1'b0;         // 模拟 ST_SCAN 在结束当拍撤一拍请求
    wire        sec_read  = rd_window && !cli_drop;
    wire [7:0]  sec_data;
    wire        sec_dv;
    wire        sec_end;

    wire SD_nCS, SD_DCLK, SD_MOSI, SD_MISO;
    wire sd_init_done;

    sd_card_top #(
        .SPI_LOW_SPEED_DIV  (16'd4),
        .SPI_HIGH_SPEED_DIV (16'd0)
    ) dut (
        .clk                    (clk),
        .rst                    (rst),
        .SD_nCS                 (SD_nCS),
        .SD_DCLK                (SD_DCLK),
        .SD_MOSI                (SD_MOSI),
        .SD_MISO                (SD_MISO),
        .sd_init_done           (sd_init_done),
        .sd_sec_read            (sec_read),
        .sd_sec_read_addr       (sec_addr),
        .sd_sec_read_count      (sec_count),
        .sd_sec_read_data       (sec_data),
        .sd_sec_read_data_valid (sec_dv),
        .sd_sec_read_end        (sec_end),
        .sd_sec_write           (1'b0),
        .sd_sec_write_addr      (32'd0),
        .sd_sec_write_data      (8'd0),
        .sd_sec_write_data_req  (),
        .sd_sec_write_end       ()
    );

    // ------------------------------------------------------------------
    // SPI 卡模型
    //   ph=0 等命令 / 1 收命令剩余 5 字节 / 2 发 R1 / 3 发哑字节 / 4 发数据块
    // ------------------------------------------------------------------
    integer    lat        = 40;
    integer    dbg        = 0;
    reg [7:0]  rxbuf      = 8'h00;
    reg [2:0]  bitc       = 3'd0;     // 本字节已采样位数
    reg [7:0]  txb        = 8'hFF;
    reg [2:0]  ph         = 3'd0;
    reg [2:0]  cmd_bytes  = 3'd0;
    reg [47:0] cmdq       = 48'd0;
    reg [31:0] cur_lba    = 32'd0;
    integer    tok_wait   = 0;
    integer    dleft      = 0;        // 本块 token 之后剩余字节（512 数据 + 2 CRC）
    integer    didx       = 0;        // 本块已发数据字节
    reg [3:0]  init_tries = 4'd0;
    reg        is_read    = 1'b0;
    reg        is_stream  = 1'b0;

    // 卡片数据输出延迟 tODLY（0 延时模型会掩盖 master 采样点问题：
    // 真实卡在下降沿之后 2~15ns 才把新数据送到 MISO，且必须一直保持到
    // 下一个下降沿。这里给 15ns，既覆盖最坏 tODLY，也让"最后一个 bit 在
    // 上升沿被 handle_byte 改掉"这种零延时假象无法蒙混过关）
    wire #15 SD_MISO_d;
    assign SD_MISO_d = txb[7];
    assign SD_MISO   = SD_MISO_d;

    always @(posedge SD_nCS) if (dbg > 1) $display("[%0t] CS high", $time);
    always @(negedge SD_nCS) if (dbg > 1) $display("[%0t] CS low", $time);

    // CS 下降沿：字节边界重新对齐（DCLK 空闲为高，第一个下降沿是字节第 1 位）
    always @(negedge SD_nCS)
        bitc <= 3'd0;

    // CS 上升沿：字节边界复位。注意真实卡抬 CS 并不会终止 CMD18 流——
    // 流必须由 CMD12 (STOP_TRANSMISSION) 终止；流未终止时卡仍处于数据发送态，
    // 重新选中后发来的新命令在 DO 上只能读出数据残留，得不到合法 R1。
    // is_stream 因此只在 CMD12 时清除（见 do_cmd），守住"忘发 CMD12"回归
    always @(posedge SD_nCS) begin
        ph  <= 3'd0;
        txb <= 8'hFF;
    end

    // 上升沿采样 MOSI
    always @(posedge SD_DCLK) if (!SD_nCS) begin
        rxbuf <= {rxbuf[6:0], SD_MOSI};
        if (bitc == 3'd7) begin
            bitc <= 3'd0;
            handle_byte({rxbuf[6:0], SD_MOSI});
        end else
            bitc <= bitc + 3'd1;
    end

    // 下降沿换 MISO：每字节第 1 个下降沿不移位（此时 MSB 已就位）
    always @(negedge SD_DCLK) if (!SD_nCS && bitc != 3'd0)
        txb <= {txb[6:0], 1'b1};

    task handle_byte(input [7:0] b);
        begin
            if (dbg > 0) $display("[%0t] RX %02x ph=%0d", $time, b, ph);
            case (ph)
            3'd0: begin
                if (b[7:6] == 2'b01) begin
                    if (is_stream && b[5:0] != 6'd12) begin
                        // CMD18 流未终止就发新命令：DO 上是数据残留（0x00，
                        // bit7=0），不是 R1。合法 DUT 应先发 CMD12 停流
                        txb = 8'h00;
                    end else begin
                        ph        = 3'd1;
                        cmd_bytes = 3'd1;
                        cmdq      = {b, 40'd0};
                        txb       = 8'hFF;
                    end
                end
            end
            3'd1: begin
                case (cmd_bytes)
                    3'd1: cmdq[39:32] = b;
                    3'd2: cmdq[31:24] = b;
                    3'd3: cmdq[23:16] = b;
                    3'd4: cmdq[15:8]  = b;
                    3'd5: begin
                        cmdq[7:0] = b;
                        do_cmd(cmdq);
                        ph = 3'd2;
                    end
                    default: ;
                endcase
                cmd_bytes = cmd_bytes + 3'd1;
            end
            3'd2: begin
                // R1 已发完：读命令进入 token 等待，其余回空闲
                if (is_read) begin
                    tok_wait = lat;
                    if (tok_wait <= 0) begin
                        ph    = 3'd4;
                        txb   = 8'hFE;
                        dleft = 514;
                        didx  = 0;
                    end else begin
                        ph  = 3'd3;
                        txb = 8'hFF;
                    end
                end else begin
                    ph  = 3'd0;
                    txb = 8'hFF;
                end
            end
            3'd3: begin
                tok_wait = tok_wait - 1;
                if (tok_wait <= 0) begin
                    ph    = 3'd4;
                    txb   = 8'hFE;
                    dleft = 514;
                    didx  = 0;
                end else
                    txb = 8'hFF;
            end
            3'd4: begin
                if (b == 8'h4C && is_stream) begin
                    // 流式输出期间收到 CMD12：真实卡在完成当前块后停止输出。
                    // 模型直接切到命令接收（DUT 读完最后一块才发 CMD12，
                    // 最多刚开头一个新 token，丢弃不影响数据正确性）
                    ph        = 3'd1;
                    cmd_bytes = 3'd1;
                    cmdq      = {b, 40'd0};
                    txb       = 8'hFF;
                end else if (dleft == 0) begin
                    // 本块结束：流式读继续下一扇区，否则回空闲
                    if (is_stream) begin
                        cur_lba = cur_lba + 32'd1;
                        txb     = 8'hFE;
                        dleft   = 514;
                        didx    = 0;
                    end else begin
                        ph  = 3'd0;
                        txb = 8'hFF;
                    end
                end else begin
                    if (didx < 512)
                        txb = (cur_lba + didx) & 32'hFF;
                    else
                        txb = 8'hFF;              // CRC
                    didx  = didx + 1;
                    dleft = dleft - 1;
                end
            end
            default: ph = 3'd0;
            endcase
        end
    endtask

    task do_cmd(input [47:0] c);
        reg [5:0] op;
        begin
            op = c[45:40];
            if (dbg > 0) $display("[%0t] CMD %0d arg=%08x", $time, op, c[39:8]);
            is_read   = 1'b0;
            is_stream = 1'b0;
            case (op)
                6'd0 : txb = 8'h01;
                6'd8 : txb = 8'h01;
                6'd55: txb = 8'h01;
                6'd41: begin
                    init_tries = init_tries + 4'd1;
                    txb = (init_tries >= 4'd2) ? 8'h00 : 8'h01;
                end
                6'd16: txb = 8'h00;
                6'd12: begin
                    // STOP_TRANSMISSION：终止 CMD18 流，回 R1=0x00
                    //（随后 DO 回 0xFF，DUT 靠此判断停止完成）
                    txb = 8'h00;
                end
                6'd17: begin
                    txb     = 8'h00;
                    is_read = 1'b1;
                    cur_lba = c[39:8];
                end
                6'd18: begin
                    txb       = 8'h00;
                    is_read   = 1'b1;
                    is_stream = 1'b1;
                    cur_lba   = c[39:8];
                end
                default: txb = 8'hFF;
            endcase
        end
    endtask

    // ------------------------------------------------------------------
    // 数据校验：期望字节 = (base + 已读扇区号 + 扇区内偏移) & 0xFF
    // ------------------------------------------------------------------
    integer    nerr = 0, nend = 0;
    reg [31:0] base = 32'd0;
    integer    bidx = 0;

    always @(posedge clk) begin
        if (!rst && sec_dv) begin
            if (sec_data !== ((base + nend + bidx) & 32'hFF)) begin
                if (nerr < 8)
                    $display("DATA ERR sec=%0d i=%0d got %02x exp %02x",
                             nend, bidx, sec_data, (base + nend + bidx) & 32'hFF);
                nerr = nerr + 1;
            end
            bidx = bidx + 1;
        end
        if (!rst && sec_end) begin
            if (bidx != 512) begin
                $display("LEN ERR sec=%0d got %0d", nend, bidx);
                nerr = nerr + 1;
            end
            bidx = 0;
            nend = nend + 1;
        end
    end

    // ------------------------------------------------------------------
    // 单扇区客户端模型（复现 bmp_read 的真实时序）
    //   真实链路里 sec_end 到 bmp_read 还多一级 bmp_e_q 寄存，而且 ST_LOAD_DATA
    //   期间 sd_sec_read 一直保持高（只有 ST_SCAN 会在结束当拍撤一拍）。
    //   所以客户端是在 sec_end 之后第 2 拍才更新地址，而请求始终为高。
    //     +LAG=0  理想客户端（旧 TB 行为，测不出"地址锁存过早"）
    //     +LAG=1  等价 bmp_read（默认）：地址晚一拍，请求不撤
    //     +DROP=1 再叠加 ST_SCAN 式的"结束当拍撤一拍请求"
    // ------------------------------------------------------------------
    integer   lag = 1;
    integer   drop_en = 0;
    reg [2:0] end_d = 3'd0;
    reg       cli_end;

    always @(*) begin
        case (lag)
            0:       cli_end = sec_end;
            1:       cli_end = end_d[0];
            2:       cli_end = end_d[1];
            default: cli_end = end_d[2];
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            end_d    <= 3'd0;
            cli_drop <= 1'b0;
            sec_addr <= 32'd0;
        end else begin
            end_d <= {end_d[1:0], sec_end};
            if (cli_end && sec_count == 16'd1) begin
                sec_addr <= sec_addr + 32'd1;
                cli_drop <= (drop_en != 0);
            end else
                cli_drop <= 1'b0;
        end
    end

    // ------------------------------------------------------------------
    // 激励与吞吐统计
    // ------------------------------------------------------------------
    integer n_sec = 64;
    time    t0, t1;
    real    us_single, us_stream;

    task run_read(input [31:0] a, input integer n, input integer cnt,
                  output time tstart, output time telapsed);
        begin
            base      = a;
            nend      = 0;
            bidx      = 0;
            @(negedge clk);
            sec_addr  = a;
            sec_count = cnt[15:0];
            rd_window = 1'b1;
            tstart    = $time;
            while (nend < n) @(posedge clk);
            telapsed  = $time;
            @(negedge clk);
            rd_window = 1'b0;
            repeat (20) @(posedge clk);
        end
    endtask

    task report(input [8*12-1:0] name, input time tstart, input time tend);
        real us_per, mbps;
        begin
            us_per = (tend - tstart) / 1000.0 / n_sec;
            mbps   = (n_sec * 512.0) / (tend - tstart) * 1000.0;
            $display("%0s: %0d sectors, %0d cycles/sector, %.2f us/sector, %.2f MB/s",
                     name, n_sec, (tend - tstart) / 10 / n_sec, us_per, mbps);
            $display("   201-sector frame = %.2f ms (budget 41.67 ms)",
                     us_per * 201 / 1000.0);
        end
    endtask

    initial begin
        if ($value$plusargs("N=%d", n_sec)) ;
        if ($value$plusargs("LAT=%d", lat)) ;
        if ($value$plusargs("LAG=%d", lag)) ;
        if ($value$plusargs("DROP=%d", drop_en)) ;
        if ($value$plusargs("DBG=%d", dbg)) ;
        repeat (20) @(posedge clk);
        rst = 1'b0;
        wait (sd_init_done === 1'b1);
        repeat (20) @(posedge clk);
        $display("init done");

        // ---- 单扇区 CMD17 ----
        run_read(32'd47360, n_sec, 1, t0, t1);
        report("CMD17", t0, t1);

        // ---- 流式 CMD18 ----
        run_read(32'd60000, n_sec, n_sec, t0, t1);
        report("CMD18", t0, t1);

        // ---- 连续两批流式（跨批：CS 抬升后重发命令）----
        run_read(32'd70000, n_sec, n_sec, t0, t1);
        report("CMD18#2", t0, t1);

        // ---- 流式读结束回到单扇区（视频层切走 → BMP/WAV 恢复读）----
        run_read(32'd80000, n_sec, 1, t0, t1);
        report("CMD17-resume", t0, t1);

        if (nerr == 0 && nend == n_sec)
            $display("TB_SD_TIMING PASS (last batch %0d sectors)", nend);
        else
            $display("TB_SD_TIMING FAIL nerr=%0d nend=%0d", nerr, nend);
        $finish;
    end

    initial begin
        #200000000;
        $display("TIMEOUT nend=%0d nerr=%0d ph=%0d", nend, nerr, ph);
        $finish;
    end

endmodule
