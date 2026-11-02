// ============================================================================
// wr_fin_split — 共享帧写口的完成信号按归属拆分（ext_mem_clk 域）
//
// frame_fifo_write 只有一路 write_finish，而写口由 BMP 与视频帧分时复用。
// 旧版把这一路直接翻成 toggle 喂给 video_frame_fill：只要 BMP 后台装载完成
// （或视频收尾时归属已切换），都会误翻视频显示缓冲，表现为花屏/撕裂。
//
// 这里在写请求应答时锁存归属，写完成时按归属分别产生两路 toggle：
//   o_vf_tgl  → video_frame_fill 切显示缓冲
//   o_bmp_tgl → sd_card_bmp 的 BMP 装载完成
// 归属在应答时锁存，因此"写到一半视频层被关掉"仍能正确归类。
// ============================================================================
`timescale 1ns/1ps

module wr_fin_split (
    input  wire clk,            // ext_mem_clk（frame_fifo_write 的 mem_clk）
    input  wire rst,
    input  wire i_owner,        // 写请求归属：1=视频（sd_card_clk 域，准静态）
    input  wire i_wr_ack,       // 写口应答（同 clk 域）
    input  wire i_wr_finish,    // 写完成单拍（同 clk 域）
    output reg  o_vf_tgl,
    output reg  o_bmp_tgl
);

    reg own_s1, own_s2;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            own_s1 <= 1'b0;
            own_s2 <= 1'b0;
        end else begin
            own_s1 <= i_owner;
            own_s2 <= own_s1;
        end
    end

    reg pending;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pending   <= 1'b0;
            o_vf_tgl  <= 1'b0;
            o_bmp_tgl <= 1'b0;
        end else begin
            if (i_wr_ack)
                pending <= own_s2;
            if (i_wr_finish) begin
                pending <= 1'b0;
                if (pending)
                    o_vf_tgl <= ~o_vf_tgl;
                else
                    o_bmp_tgl <= ~o_bmp_tgl;
            end
        end
    end

endmodule
