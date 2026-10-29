# 仿真测试平台

本目录为 ModelSim/QuestaSim 回归用例，覆盖图片链路、WAV 链路、OSD、控制与频谱。

## 用例

| 测试平台 | DUT | 验证重点 |
|---|---|---|
| `tb_wav_path.v` | `sd_card_wav` + `wav_i2s_source` | 扇区连续、FIFO 不溢出、ASRC 速率、无丢字/重字 |
| `tb_bmp_stride.v` | `bmp_read` | 行尾对齐填充、宽高保护、提前结束 |
| `tb_scaler.v` / `tb_scaler2.v` / `tb_scaler3.v` | `scaler` | 放大、缩小、1:1 |
| `tb_bmp_scaler.v` | `bmp_read` + `scaler` | 整帧装载：源帧被完整消费（`ready` 回 1）、输出 307200 像素；`+BMP=<路径>` 指定图片 |
| `tb_frame_fifo.v` | `frame_fifo_write` | 突发读数与不读空 |
| `tb_bc.v` | `brightness_contrast` | 5 档亮度/对比度 |
| `tb_ctrl.v` | `ctrl`（依赖 `key_press_debounce`） | 按键循环与 SW 分层 |
| `tb_fade.v` | `fade_ctrl` | 淡出/淡入状态机 |
| `tb_transition.v` | `transition_ctrl` | fade + wipe 遮罩 |
| `tb_osd.v` / `tb_scroll.v` / `tb_short.v` | `osd_layer` + `font8x8` | 启动面板、上下栏、频谱、滚动 |
| `tb_slogan.v` | `slogan_ctrl` | UART 行解析 |
| `tb_spectrum.v` | `audio_spectrum` | 1kHz 频段定位 |
| `tb_font.v` | `font8x8` | 小写字形非零 |
| `tb_bmp_cycle.v` | `sd_card_bmp` 整链 | 16 图扫描 + 9 图连续轮播 + WAV 总线竞争无死锁；`+START=<扇区>` 模拟大元数据区（exFAT）、`+DROP=<sector>` 注入丢请求验证看门狗恢复 |
| `tb_egv_reader.v` | `egv_reader` | 段表跨段换算、视频/音频字节拆分、末帧停机与重启（需 `+incdir+.../video`） |
| `tb_video_frame_fill.v` | `video_frame_fill` | 2 倍放大、296 行写入、双 bank 切换与首帧初始化（依赖 `eg_logic_bram_sim.v`） |
| `tb_egv_audio_fifo.v` | `egv_audio_fifo` | 字节流重排为 s16 立体声、FWFT 读、flush |
| `tb_danmaku_osd.v` | `danmaku_osd` | 两轨道排队、逐字变色、滚完才消失 |
| `tb_resmon_osd.v` | `resmon_osd` | 面板边框、占用条长度、百分比与信息行 |

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

> 2026-10-29 复跑：`tb_ctrl`、`tb_slogan`、`tb_danmaku_osd`、`tb_resmon_osd`、`tb_video_frame_fill`、`tb_egv_audio_fifo`、`tb_egv_reader`、`tb_osd_layer`、`tb_spectrum`、`tb_bmp_cycle`（6 图 + 12 次切换）全部 PASS。结果记录见 [验证记录](../docs/05-验证记录.md)。

视频相关用例需要额外文件：

```bash
vlog eg_logic_bram_sim.v ../src/user_source/hdl_source/video/video_frame_fill.v tb_video_frame_fill.v
vlog +incdir+../src/user_source/hdl_source/video ../src/user_source/hdl_source/video/egv_reader.v tb_egv_reader.v
vlog eg_logic_bram_sim.v ../src/user_source/hdl_source/video/egv_audio_fifo.v tb_egv_audio_fifo.v
```
