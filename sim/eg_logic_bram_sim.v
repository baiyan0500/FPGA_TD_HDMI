`timescale 1ns/1ps
// 行为级 EG_LOGIC_BRAM（仅供 ModelSim 功能仿真，TD 库原件加密无法编译）
// 同步读：addrb 给出后下一拍 dob 有效（与 NOREG 配置一致）
module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A = 18,
    parameter ADDR_WIDTH_A = 10,
    parameter DATA_WIDTH_B = 18,
    parameter ADDR_WIDTH_B = 10,
    parameter MODE = "DP",
    parameter REGMODE_A = "NOREG",
    parameter REGMODE_B = "NOREG",
    parameter WRITEMODE_A = "NORMAL",
    parameter WRITEMODE_B = "NORMAL",
    parameter RESETMODE = "SYNC",
    parameter IMPLEMENT = "9K",
    parameter INIT_FILE = ""
)(
    input  wire [DATA_WIDTH_A-1:0] dia,
    input  wire [ADDR_WIDTH_A-1:0] addra,
    input  wire cea,
    input  wire ocea,
    input  wire clka,
    input  wire wea,
    input  wire rsta,
    input  wire bea,
    input  wire [DATA_WIDTH_B-1:0] dib,
    input  wire [ADDR_WIDTH_B-1:0] addrb,
    input  wire ceb,
    input  wire oceb,
    input  wire clkb,
    input  wire web,
    input  wire rstb,
    input  wire beb,
    output reg  [DATA_WIDTH_A-1:0] doa,
    output reg  [DATA_WIDTH_B-1:0] dob
);

reg [DATA_WIDTH_A-1:0] mem [0:(1<<ADDR_WIDTH_A)-1];

initial begin
    doa = {DATA_WIDTH_A{1'b0}};
    dob = {DATA_WIDTH_B{1'b0}};
end

always @(posedge clka) begin
    if (rsta) begin
        doa <= {DATA_WIDTH_A{1'b0}};
    end else if (cea) begin
        if (wea) mem[addra] <= dia;
        doa <= mem[addra];
    end
end

always @(posedge clkb) begin
    if (rstb) begin
        dob <= {DATA_WIDTH_B{1'b0}};
    end else if (ceb) begin
        if (web) mem[addrb] <= dib;
        dob <= mem[addrb];
    end
end

endmodule
