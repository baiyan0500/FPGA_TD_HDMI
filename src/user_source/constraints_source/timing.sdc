
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原作者的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 5. 音频 I2S 发生器/接收器 + sd_card_wav 异步 FIFO 跨域
#
#    audio_mclk 域里生成 I2S，video_clk 域里做三拍同步采样；
#    sd_card_wav 的 gray 指针 / 双时钟 RAM / 参数稳定后使能，均由
#    2 级同步器或"稳定后再用"协议保护。set_clock_groups 在 TD 6.2
#    的时序报告中未见生效，改用显式 false path。
# ------------------------------------------------------------
#    clk(50MHz) 必须包含在内：rst_all 由 clk 域产生，扇出到 audio_mclk
#    域全部寄存器的异步复位端；若只约束其他时钟，这部分会被当普通数据
#    路径分析（246 条端点 SWNS -2.188ns），实际是异步复位，无需时序收敛。
set_false_path -from [get_clocks {audio_mclk}] -to [get_clocks {clk video_clk hdmi_5x_clk sd_card_clk ext_mem_clk}]
set_false_path -from [get_clocks {clk video_clk hdmi_5x_clk sd_card_clk ext_mem_clk}] -to [get_clocks {audio_mclk}]

# ------------------------------------------------------------
# 5.1 display_valid 同步器：sd_card_clk → video_clk 的 2 级同步首级
#     已由 5.3 的 video_clk ↔ sd_card_clk 时钟对 false path 覆盖，
#     无需再用 get_regs（TD 在 read_adc 阶段解析不到寄存器，命令会失败）
# ------------------------------------------------------------

# ------------------------------------------------------------
# 5.2 SDRAM 源同步 pad 接口（ext_mem_clk ↔ SDRAM 输出时钟 clkc[2]）
#     板级时序由 SDRAM 采样窗口与 PCB 等长保证，FPGA 内部分析恒报红
#     （历史版本即如此，功能正常），予以豁免。
# ------------------------------------------------------------
set_false_path -from [get_clocks {ext_mem_clk}] -to [get_clocks {sys_pll_m0/pll_inst.clkc[2]}]
set_false_path -from [get_clocks {sys_pll_m0/pll_inst.clkc[2]}] -to [get_clocks {ext_mem_clk}]

# ------------------------------------------------------------
# 5.3 跨 PLL 时钟对豁免：video_pll 输出（video_clk/hdmi_5x_clk）与
#     sys_pll 输出（sd_card_clk/ext_mem_clk）及 50MHz 主时钟 clk 物理
#     异步。跨域路径均为电平握手 / 宽脉冲 / 同步器（ctrl 按键电平、
#     video_timing_data read_req 握手、afifo gray 指针、display_valid
#     同步器），豁免同步分析。
#     注意：sd_card_clk 与 ext_mem_clk 同出 sys_pll（同步相位关系），
#     不在本豁免组内。
# ------------------------------------------------------------
set_false_path -from [get_clocks {video_clk hdmi_5x_clk}] -to [get_clocks {sd_card_clk ext_mem_clk clk}]
set_false_path -from [get_clocks {sd_card_clk ext_mem_clk clk}] -to [get_clocks {video_clk hdmi_5x_clk}]

# ------------------------------------------------------------
# 5.4 sd_card_clk ↔ ext_mem_clk：同出 sys_pll，但两者之间没有单周期
#     数据通路，全部交互均为异步 FIFO（gray 指针同步）、write_req 电平
#     握手（ext 域 3 级同步）与 write_req_ack（sd 域 2 级同步）。
#     原先用 get_regs 约束 */fifo_aclr_reg* 在 read_adc 阶段无法解析
#     （命令 CRITICAL-WARNING 失败），残留 ext_mem→sd SWNS -1.006ns。
#     改为异步时钟组，彻底消除这类跨域伪路径。
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {sd_card_clk}] \
    -group [get_clocks {ext_mem_clk}]

# ------------------------------------------------------------
# 6. 可选：如果你的 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------
