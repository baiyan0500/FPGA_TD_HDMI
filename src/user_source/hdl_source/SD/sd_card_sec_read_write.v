
module sd_card_sec_read_write
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 0           // spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
	output reg       sd_init_done,
	input            sd_sec_read,
	input[31:0]      sd_sec_read_addr,
	input[15:0]      sd_sec_read_count,   // 连续读扇区数（>1 时用 CMD18 流式读）
	output[7:0]      sd_sec_read_data,
	output           sd_sec_read_data_valid,
	output           sd_sec_read_end,
	input            sd_sec_write,
	input[31:0]      sd_sec_write_addr,
	input[7:0]       sd_sec_write_data,
	output           sd_sec_write_data_req,
	output           sd_sec_write_end,

	output reg[15:0] spi_clk_div,
	output reg       cmd_req,
	input            cmd_req_ack,
	input            cmd_req_error,
	output reg[47:0] cmd,
	output reg[7:0]  cmd_r1,
	output reg[15:0] cmd_data_len,
	output reg       block_read_req,
	input            block_read_valid,
	input[7:0]       block_read_data,
	input            block_read_req_ack,
	output reg       block_write_req,
	output[7:0]      block_write_data,
	input            block_write_data_rd,
	input            block_write_req_ack
);
reg[7:0] read_data;
reg[31:0] timer;

localparam S_IDLE               = 0;
localparam S_CMD0               = 1;
localparam S_CMD8               = 2;
localparam S_CMD55              = 3;
localparam S_CMD41              = 4;
localparam S_CMD17              = 5;
localparam S_READ               = 6;
localparam S_CMD24              = 7;
localparam S_WRITE              = 8;
localparam S_ERR                = 14;
localparam S_WRITE_END          = 15;
localparam S_READ_END           = 16;
localparam S_WAIT_READ_WRITE    = 17;
localparam S_CMD16              = 18;
localparam S_CMD18              = 19;
localparam S_READ_WAIT          = 20;   // 结束脉冲之后先空等两拍（S_READ_WAIT/S_READ_WAIT2），
                                        // 让客户端有时间把地址更新到 sd_sec_read_addr
// 结束脉冲到客户端的路径：sec_end_pulse → rd_end_q（本文件）→ bmp_e_q（sd_card_bmp）
// 共 2 级寄存，客户端因此在 sec_end_pulse 之后第 3 拍才更新地址并在同一拍撤销
// sd_sec_read。寄一拍不够：核心仍在第 2 拍就把老地址锁进 sec_addr，于是每个扇区
// 都重发上一条 CMD17（扫描永远停在扇区 0，装载/视频全部拿不到数据）。
// 再补一拍，核心在客户端撤销那一拍先看到 sd_sec_read=0 不锁存，
// 下一拍才在"请求已恢复、地址已更新"的状态下取地址。
localparam S_READ_WAIT2         = 21;

reg[4:0]                       state;
reg[31:0]                      sec_addr;
reg[15:0]                      sec_left;       // 本批剩余扇区数（含当前扇区）
reg                            sec_end_pulse;  // 每扇区结束单拍脉冲

// 读数据/有效/结束三者寄存一级后一起输出：原来 valid = state 组合译码直连所有
// 客户端的字节计数器，形成"SD 核 state → bmp_read/wav 计数 CE"约 10.5ns 的长链。
// 三者同拍延迟，对客户端只相当于整体晚一拍，字节流与扇区结束的相对时序不变。
reg [7:0]                      rd_data_q;
reg                            rd_valid_q;
reg                            rd_end_q;
always@(posedge clk or posedge rst) begin
    if(rst) begin
        rd_data_q  <= 8'd0;
        rd_valid_q <= 1'b0;
        rd_end_q   <= 1'b0;
    end else begin
        rd_data_q  <= block_read_data;
        rd_valid_q <= (state == S_READ) && block_read_valid;
        rd_end_q   <= sec_end_pulse;
    end
end
assign sd_sec_read_data_valid = rd_valid_q;
assign sd_sec_read_data = rd_data_q;
assign sd_sec_read_end = rd_end_q;
assign sd_sec_write_data_req = (state == S_WRITE) && block_write_data_rd;
assign block_write_data = sd_sec_write_data;
assign sd_sec_write_end = (state == S_WRITE_END);

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		cmd_req <= 1'b0;
		cmd_data_len <= 16'd0;
		cmd_r1 <= 8'd0;
		cmd <= 48'd0;
		spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
		block_write_req <= 1'b0;
		block_read_req <= 1'b0;
		sec_addr <= 32'd0;
		sec_left <= 16'd1;
		sec_end_pulse <= 1'b0;
		sd_init_done <= 1'b0;
	end
	else
	begin
		sec_end_pulse <= 1'b0;
		case(state)
			S_IDLE:
			begin
				state <= S_CMD0;
				sd_init_done <= 1'b0;
				spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
			end
			S_CMD0:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD8;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd0,8'h00,8'h00,8'h00,8'h00,8'h95};
				end
			end
			S_CMD8:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD55;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd4;
					cmd_r1 <= 8'h01;
					cmd <= {8'd8,8'h00,8'h00,8'h01,8'haa,8'h87};
				end
			end
			S_CMD55:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD41;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd55,8'h00,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD41:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD16;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd41,8'h40,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD16:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WAIT_READ_WRITE;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd16,32'd512,8'hff};
				end
			end			
			S_WAIT_READ_WRITE:
			begin
				if(sd_sec_write ==  1'b1)
				begin
					state <= S_CMD24;
					sec_addr <= sd_sec_write_addr;
				end
				else if(sd_sec_read == 1'b1)
				begin
					sec_addr <= sd_sec_read_addr;
					sec_left <= (sd_sec_read_count <= 16'd1) ? 16'd1 : sd_sec_read_count;
					state    <= (sd_sec_read_count > 16'd1) ? S_CMD18 : S_CMD17;
				end

				spi_clk_div <= 16'd0;
			end
			S_CMD24:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WRITE;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd24,sec_addr,8'hff};

				end
			end
			S_WRITE:
			begin
				if(block_write_req_ack == 1'b1)
				begin
					block_write_req <= 1'b0;
					state <= S_WRITE_END;
				end
				else
					block_write_req <= 1'b1;
			end
			S_CMD17:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_READ;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd17,sec_addr,8'hff};
				end
			end
			S_CMD18:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_READ;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd18,sec_addr,8'hff};
				end
			end
			S_READ:
			begin
				if(block_read_req_ack)
				begin
					sec_end_pulse <= 1'b1;
					if(sec_left <= 16'd1)
					begin
						state <= S_READ_END;
						block_read_req <= 1'b0;
					end
					else
						sec_left <= sec_left - 16'd1;
				end
				else
				begin
					block_read_req <= 1'b1;
				end
			end
			S_WRITE_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			S_READ_END:
			begin
				state <= S_READ_WAIT;
			end
			S_READ_WAIT:
			begin
				state <= S_READ_WAIT2;
			end
			S_READ_WAIT2:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			default:
				state <= S_IDLE;
		endcase
	end
end
endmodule