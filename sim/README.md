# 仿真测试平台

本目录为 ModelSim/QuestaSim 回归用例，覆盖图片链路、WAV 链路、OSD、控制与频谱。

## 用例

| 测试平台 | DUT | 验证重点 |
|---|---|---|
| `tb_wav_path.v` | `sd_card_wav` + `wav_i2s_source` | 扇区连续、FIFO 不溢出、ASRC 速率、无丢字/重字；`+HDR=0/1/2` 覆盖标准头、fmt 后带 LIST/INFO（data 非 4 字节对齐）、奇数 chunk 带填充 |
| `tb_bmp_stride.v` | `bmp_read` | 行尾对齐填充、宽高保护、提前结束 |
| `tb_scaler.v` / `tb_scaler2.v` / `tb_scaler3.v` | `scaler` | 放大、缩小、1:1 |
| `tb_bmp_scaler.v` | `bmp_read` + `scaler` | 整帧装载：源帧被完整消费（`ready` 回 1）、输出 307200 像素；`+BMP=<路径>` 指定图片 |
| `tb_frame_fifo.v` | `frame_fifo_write` | 突发读数与不读空 |
| `tb_bc.v` | `brightness_contrast` | 5 档亮度/对比度 |
| `tb_ctrl.v` | `ctrl`（依赖 `key_press_debounce`） | 按键循环与 SW 分层；SW4 独立告警使能、不改变功能层 |
| `tb_fade.v` | `fade_ctrl` | 淡出/淡入状态机 |
| `tb_transition.v` | `transition_ctrl` | fade + wipe 遮罩 |
| `tb_osd.v` / `tb_scroll.v` / `tb_short.v` | `osd_layer` + `font8x8` | 启动面板、上下栏、频谱、滚动 |
| `tb_warning_osd.v` | `osd_layer` + `font8x8` | SW4 全屏告警层最高优先级：3 个呼吸相位下**整屏 640×480 逐像素**比对（压暗染红底图、上下 45° 斜纹带、卡片 4px 红边/2px 琥珀内线、4 倍字号 WARNING、4 行 2 倍字号说明）、关闭时完全透明、与启动面板叠加、呼吸三角波 |
| `tb_warn_dump.v` | `osd_layer` | 把 SW4 告警层渲染成 3 帧 PPM（暗/中/亮相位）供人工核对外观；`tools/ppm2png.js` 转 PNG |
| `tb_slogan.v` | `slogan_ctrl` | UART 行解析 |
| `tb_spectrum.v` | `audio_spectrum` | 64 bin/32 段：1kHz、4kHz、60Hz 频段定位，静音两窗归零（s2 清零），-6/-36dBFS 电平差约 23 级 |
| `tb_font.v` | `font8x8` | 小写字形非零 |
| `tb_bmp_cycle.v` | `sd_card_bmp` 整链 | 16 图扫描 + 9 图连续轮播 + WAV 总线竞争无死锁 + 视频独占扇区边界交接（中途请求独占必须等扇区结束，装载不丢字节、不触发看门狗）；`+START=<扇区>` 模拟大元数据区（exFAT）、`+DROP=<sector>` 注入丢请求验证看门狗恢复 |
| `tb_bmp_egv_scan.v` | `bmp_read` 扫描 | EGV1 魔数命中后按头内文件长度跳转（越界立即收工、窗口内不读中间扇区），畸形长度至少前进 8 扇区不锁死 |
| `tb_sd_timing.v` | `sd_card_top`（真实 SPI 模式 3 卡模型） | CMD17/CMD18 扇区读：逐字节数据与扇区计数校验、吞吐统计（CMD18 约 185.7µs/扇区 → 201 扇区/帧 37.3ms）、CMD18 批次后立即恢复单扇区读；`+N=<扇区数>` 调整批量，`+LAG=<n>` 客户端地址滞后拍数（默认 1 = 等价 `bmp_read` 的两级结束寄存，0 = 理想客户端），`+DROP=<n>` 叠加 ST_SCAN 式撤一拍请求 |
| `tb_egv_reader.v` | `egv_reader` | 段表跨段换算、视频/音频字节拆分、末帧停机与重启；连跑 90 帧（越过 16,600 扇区）逐扇区校验地址与**CMD18 批长 = min(段剩余, 帧剩余)**，覆盖 16bit 段计数器溢出回归（需 `+incdir+.../video`）；跨段批长取自预寄存的 `nxt_len_q/batch_nx_q`，read_end 那拍只搬寄存器 |
| `tb_egv_reader_rt.v` | `egv_reader` | 运行时段表回归：3 段合法头→M_RT、坏魔数→M_NONE 不读数据、run0 起点不符→M_CONTIG、扫描未命中时探编译期 LBA、字段损坏且在原 LBA→M_CONST |
| `tb_real_reader.v` | `egv_reader` + 真实卡模型 | 用卡上真实容器头/段表（`real_mem.hex`）驱动 2 帧，94720 个 RGB565 像素逐像素比对；卡模型按 CMD18 流式语义一次发 `o_sd_count` 个物理连续扇区、每扇区一拍 `read_end`、批结束留重采样空隙，覆盖帧内跨段分批判长 |
| `tb_video_frame_fill.v` | `video_frame_fill` | 2 倍放大、296 行写入、双 bank 切换与首帧初始化、`o_frame_ok/o_pix_cnt` 帧完整性自证位、`pad` 补零收尾与 90ms 停滞看门狗（依赖 `eg_logic_bram_sim.v`） |
| `tb_egv_audio_fifo.v` | `egv_audio_fifo` | 字节流重排为 s16 立体声、FWFT 读、flush |
| `tb_wr_fin_split.v` | `wr_fin_split` | 写完成按应答时锁存的归属分流到 BMP/视频，归属提前掉 0 仍算视频 |
| `tb_danmaku_osd.v` | `danmaku_osd` | 两轨道排队、逐字变色、滚完才消失 |
| `tb_resmon_osd.v` | `resmon_osd` | 面板边框、占用条长度、百分比与信息行（VIDEO 行含 `OK/NG` 帧完整性自证位） |

## 运行方式

以 WAV 链路为例：

```bash
vlib work
vlog ../src/user_source/hdl_source/SD/sd_card_wav.v \
     ../src/user_source/hdl_source/wav_i2s_source.v \
     ../src/user_source/hdl_source/IP/afifo_16_32_256.v \
     tb_wav_path.v
vsim -c work.tb_wav_path -gSTEREO=0 -do "run -all; quit"
vsim -c work.tb_wav_path -gSTEREO=1 -do "run -all; quit"
```

其它用例按实例化关系编译对应 DUT 及依赖即可。

整链轮播用例：

```bash
vlog eg_logic_bram_sim.v ../src/user_source/hdl_source/SD/bmp_read.v \
     ../src/user_source/hdl_source/SD/sd_card_wav.v \
     ../src/user_source/hdl_source/SD/sd_card_bmp.v \
     ../src/user_source/hdl_source/osd/scaler.v tb_bmp_cycle.v

vsim -c -do "run -all; quit" work.tb_bmp_cycle \
     +IMG1=../doc/convert/f_backup/00_1.bmp \
     +IMG2=../doc/convert/f_backup/01_2.bmp \
     +IMG3=../doc/convert/f_backup/02_3.bmp \
     +IMG4=../doc/convert/output_bmp/1_640x480.bmp \
     +IMG5=../doc/convert/output_bmp/2_640x480.bmp \
     +IMG6=../doc/convert/output_bmp/3_640x480.bmp \
     +IMG7=../doc/convert/output_bmp/4_640x480.bmp \
     +IMG8=../doc/convert/output_bmp/5_640x480.bmp \
     +IMG9=../doc/convert/output_bmp/6_640x480.bmp \
     +WAV=../src/user_source/hdl_source/python/1.wav \
     [+START=<起始扇区>] [+WAVGAP=<空档扇区>] [+DROP=<sector>] [+STOP_ON_HANG]
```

高分辨率样本在 `doc/convert/f_backup/`（从卡上备份的 1024×577/576/518 原图），640×480 样本在 `doc/convert/output_bmp/`，不依赖 F: 卡是否插在电脑上。

注意：`tb_bmp_cycle.v` 末尾自带行为级 `sd_card_top`（同名），编译时不要再加入 `SD/sd_card_top.v`，否则会覆盖模型。`key_press_debounce` 定义在 `SD/sd_card_bmp.v` 内，`tb_ctrl` 需要一并编译。

> 2026-10-29 复跑：`tb_ctrl`、`tb_slogan`、`tb_danmaku_osd`、`tb_resmon_osd`、`tb_video_frame_fill`、`tb_egv_audio_fifo`、`tb_egv_reader`、`tb_osd_layer`、`tb_spectrum`、`tb_bmp_cycle`（6 图 + 12 次切换 + 视频独占交接）、`tb_sd_timing`、`tb_wav_path`（`+HDR=0/1/2` × 单双声道）全部 PASS。结果记录见 [验证记录](../docs/05-验证记录.md)。
>
> 同日修 bug（WAV 头 LIST 块、视频扇区边界交接、读核输出流水）后重跑：`tb_wav_path` 6 组全 PASS、`tb_bmp_cycle` 12 次切换 + 交接 `errors=0`、`tb_sd_timing` 逐字节 PASS（CMD18 185.68µs/扇区）、`tb_egv_reader` / `tb_video_frame_fill` PASS。
> 同日再修 `egv_reader` 段计数器位宽（16→20）后复跑 `tb_egv_reader`：`addr_err=0 cnt_err=0 pix_err=0 aud_err=0 eof_err=0 gate_err=0 frames=90` PASS。
>
> 2026-10-29 读核地址锁存修复：`tb_sd_timing` 原来在同一拍跟着 `sec_end` 改地址，比真实 `bmp_read` 早一拍，测不出缺陷；新增 `+LAG=1`（默认）后，修复前的 RTL 立刻 `FAIL nerr=7168`（`DATA ERR sec=1 i=1 got 01 exp 02`，整段在重读扇区 0），修复后 `+LAG=1` / `+LAG=0` / `+LAG=1 +DROP=1` 三组全 PASS（CMD18 185.77µs/扇区）。同轮 `tb_bmp_cycle`（扫描 + 18 次切换 + 视频独占交接 `errors=0`）、`tb_wav_path` 6 组、`tb_egv_reader`、`tb_video_frame_fill` 全 PASS。

SD 读核（真实 SPI 模式 3 卡模型）：

```bash
vlog ../src/user_source/hdl_source/SD/spi_master.v \
     ../src/user_source/hdl_source/SD/sd_card_cmd.v \
     ../src/user_source/hdl_source/SD/sd_card_sec_read_write.v \
     ../src/user_source/hdl_source/SD/sd_card_top.v tb_sd_timing.v
vsim -c -do "run -all; quit" work.tb_sd_timing [+N=<扇区数>]
```

WAV 头布局回归（`+HDR=0` 标准 44 字节、`+HDR=1` fmt 后带 LIST/INFO、`+HDR=2` 奇数 chunk 带填充字节）：

```bash
vlog ../src/user_source/hdl_source/SD/sd_card_wav.v \
     ../src/user_source/hdl_source/wav_i2s_source.v \
     ../src/user_source/hdl_source/IP/afifo_16_32_256.v tb_wav_path.v
vsim -c work.tb_wav_path -gSTEREO=0 -do "run -all; quit" +HDR=1
```

视频相关用例需要额外文件：

```bash
vlog eg_logic_bram_sim.v ../src/user_source/hdl_source/video/video_frame_fill.v tb_video_frame_fill.v
vlog +incdir+../src/user_source/hdl_source/video ../src/user_source/hdl_source/video/egv_reader.v tb_egv_reader.v
vlog +incdir+../src/user_source/hdl_source/video ../src/user_source/hdl_source/video/egv_reader.v tb_egv_reader_rt.v
vlog eg_logic_bram_sim.v ../src/user_source/hdl_source/video/egv_audio_fifo.v tb_egv_audio_fifo.v
vlog eg_logic_bram_sim.v ../src/user_source/hdl_source/video/wr_fin_split.v tb_wr_fin_split.v
```

SW4 告警层：

```bash
vlog eg_logic_bram_sim.v ../src/user_source/hdl_source/osd/osd_layer.v \
     ../src/user_source/hdl_source/osd/font8x8.v \
     ../src/user_source/hdl_source/osd/danmaku_osd.v \
     ../src/user_source/hdl_source/osd/resmon_osd.v tb_warning_osd.v
vsim -c -do "run -all; quit -f" work.tb_warning_osd
```

> 2026-10-31 复跑（频谱重写 + SW3 运行时段表/扫描发现 + SW4 告警层）：`tb_spectrum`（1k/4k/60Hz、静音归零、电平差）、`tb_warning_osd`、`tb_ctrl`、`tb_osd`、`tb_egv_reader`、`tb_egv_reader_rt`、`tb_bmp_egv_scan`、`tb_wr_fin_split`、`tb_video_frame_fill`、`tb_egv_audio_fifo`、`tb_danmaku_osd`、`tb_resmon_osd`、`tb_wav_path`（6 组）、`tb_bmp_cycle`、`tb_sd_timing`（3 组）全部 PASS。结果记录见 [验证记录](../docs/05-验证记录.md)。

> 2026-11-01 复跑（EGV 扫描越界回退 + CMD12 流终止）：全回归 23 项 PASS。本次修复：
> ① `bmp_read` 在 EGV 跳转越过 scan_max 时不再提前 `scan_done`，退化为 4KB 对齐步进——
> 实卡 EGV@47360 的 total_bytes 跳转点(434889)越过 scan_max(131071)，旧版在 EGV 处收工，
> WAV@58624（落在容器物理跨度内的间隙）与 4 张 BMP 全部漏扫 → `wav_found=0` →
> 音频永远播系统测试音。`tb_bmp_egv_scan` 场景 A 改为"EGV 之后窗口内仍有 WAV/BMP
> 必须被发现"的回归（实测 54 次读、wav@40、BMP@416）。
> ② `sd_card_cmd` 在 CMD18 流式读的最后一块后补发 CMD12（STOP_TRANSMISSION），
> 并等 DO 回 0xFF（busy 释放）才给 `block_read_req_ack`。SPI 模式下流中途抬 CS
> 不是终止，真实卡停留数据发送态、后续命令得不到合法 R1 → 只有视频客户端用
> CMD18，故"图片正常、唯独视频四版 bit 从未播成"。`tb_sd_timing` 卡模型改为
> 真实语义（CS 抬升不终止流、流中检测 CMD12、流未停时新命令只回 0x00 数据残留）；
> 反证：去掉 S_STOP_CMD 路由后 TB 在第二批 CMD18 处死锁超时，守卫有效。

> 2026-11-02（v22）扫描窗口 64MB→128MB（`SCAN_MAX_SECTOR=32'd262143`）：实卡 `VIDEO.EGV`
> 被拷到 LBA 143104（69.9MB）且编译期回退地址 47360 已成空扇区，扫描扫不到 → `egv_reader`
> 判 `M_NONE` 拒播（面板 `FRAME 00000` + `V:NG`）。`tb_bmp_egv_scan` 场景 A 继续守住"EGV
> 跳转点越过 `scan_max` 时退化为 4KB 步进、不得提前收工"，PASS。上板验证功能全部正常。

> 2026-11-02（v21）SPI MISO 采样点后移一拍 + 卡模型补 `tODLY`：`spi_master` 原来在
> 翻转 DCLK 的同一拍采 MISO，25MHz 下半个周期只有 20ns，卡侧 `tODLY`(≤14ns) 加 FPGA
> 输出/输入延迟后建立时间只剩 0~8ns → 偶发错字节（上板表现为满屏彩条 + 音频恒定电流声）。
> 改为翻转后一拍采样（数据窗口正中，余量 6~18ns）。同时 `tb_sd_timing` / `tb_menu_boot`
> 的卡模型由零延迟 `assign SD_MISO = txb[7]` 改为 `wire #15`，否则旧采样点在仿真里
> 永远"正确"，测不出此类缺陷。全回归 **28 项 PASS**（含 `tb_sd_timing` 的 `+LAG`/`+DROP`
> 三组与 `tb_menu_boot`）；把卡模型延迟加到 25ns（超出规范）做对照：旧采样点
> `nerr=130871` 崩溃，新采样点在 15/20ns 下仍 PASS。

> 2026-11-01（v14）egv_reader 运行时段表 8→4 段裁剪（`mp4_to_egv.py` 的 `MAX_RUNS` 同步收紧）：
> 8 段 8:1 mux 把 LUT 推到 16678/切片 98.3%，P&R Setup -1.28ns 不收敛；裁后 LUT 16098，
> seed 3 P&R 收敛 Setup +126ps / Hold +21ps / 0 FEP。`tb_egv_reader_rt` 场景 E 改为
> 4 段满深度装载（run3 生效）。全回归 23 项 PASS。
