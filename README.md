# EG4S20 HDMI 多媒体播放器（主工程）

基于安路 EG4S20BG256（HX4S20C）的纯 FPGA HDMI 音视频播放系统。TF 卡 BMP 图片经 SDRAM 双缓冲送 HDMI 显示，WAV 音频经 ASRC 与 I2S 嵌入 HDMI，叠加 OSD、转场、频谱与按键交互；TF 卡上另存一段 EGV 视频容器，可在视频层播放 320×148@24fps 画面与音轨。

## 功能清单

| 分类 | 功能 |
|---|---|
| 图片 | TF 卡 BMP 扫描（前 128MB、4KB 步进、最多 16 张）、任意分辨率≤1024×2047 最近邻缩放、双缓冲切换、手动/自动轮播 |
| 视频 | 640×480@60、HDMI 1.4b、25MHz 像素时钟；EGV 容器视频（320×148@24fps + 48kHz 音轨）2 倍放大居中播放 |
| 音频 | WAV PCM 16/24/32bit（含 `WAVE_FORMAT_EXTENSIBLE`）、单/双声道、8k~48k、ASRC→48k、HDMI 音频、循环/暂停、测试音回退 |
| 显示增强 | 亮度/对比度 5 档（百分比显示）、4 种转场（淡入淡出/右擦除/左擦除/下滑） |
| OSD | 上下信息栏、时间戳、开机启动面板、UART 标语滚动、音量峰值条、彩色弹幕、资源占用面板 |
| 可视化 | 32 段 Goertzel 频谱（47Hz~16kHz），全宽透明叠加 |
| 交互 | 三层拨码功能（图片/自动/视频）+ 按键、6 位数码管、UART 115200 |

## 目录

```
merged/
├── src/
│   ├── td_project/              # TD 工程：.al、al_ip、约束引用
│   └── user_source/
│       ├── hdl_source/          # Verilog 源码
│       ├── constraints_source/  # timing.sdc / pin.adc
│       └── ip_source/
├── docs/                        # 项目文档（入口见 docs/06-进度与迭代计划.md）
│   ├── reports/                 # Multi-Seed / check run 原始 QoR 报告
│   └── reference/               # 历史方案与官方例程说明
├── sim/                         # ModelSim 测试平台
├── tools/                       # 字模生成、docx→md 工具
└── doc/                         # 厂商 HDMI 文档、BMP 转换脚本与素材
```

## 快速开始

### 1. 打开与编译

用安路 TD 6.2 打开：

```
src/td_project/HDMI1.4b_Transmitter_v1.0.al
```

顶层模块 `top`，器件 `EG4S20BG256`（package `EG4S20BG256`）。

> 普通 Run（DefaultFlow）在默认 seed 下会于 route 的 hold fix 阶段崩溃。请使用 **Flow Runs → 右键 phy_1 → Setup Multi-Seed**，Minimum Seed=2，详见 [TD 工程与 Multi-Seed](docs/07-TD工程与MultiSeed.md)。

### 2. 准备 TF 卡

- 根目录放 BMP：24bit 非压缩，建议 640×480；工程支持任意 ≤1024×2047 分辨率缩放
- 根目录放 WAV：PCM 16/24/32bit、单/双声道、8k~48k（取扫描到的第一个 WAV，循环播放）
- 根目录放 EGV 视频容器（可选）：用 `tools/video/mp4_to_egv.py` 生成；换视频不必重新综合，但容器须在前 128MB 内且物理连续，可用 `node tools/video/egv_locate.js <盘号> VIDEO.EGV` 自检
- FAT32 / exFAT 均可；使用 `doc/convert/sync_to_sd.py` 同步，避免物理扇区残留旧图

详见 [图片与 TF 卡制作](docs/08-图片与TF卡制作.md)。

### 3. 上板操作

按键/拨码映射、UART 标语协议见 [功能与操作](docs/04-功能与操作.md)。

## 当前状态（2026-11-02）

- 功能：基础 4/4、扩展 5/5 均已实现；图片 / 视频 / 音频 / 交互全部上板跑通
- 上板修复（v20）：WAV 头解析（卡内文件 fmt 后带 LIST 块，data 偏移 70 非 4 字节对齐）；视频客户端改扇区边界独占 + CMD18 连续读；`egv_reader` 段计数器 16→20 位；读核 `S_WAIT_READ_WRITE` 采样过早补 `S_READ_WAIT2` 空等态
- 上板修复（v21）：SPI MISO 采样点从"DCLK 翻转同拍"后移一拍，采在 25MHz 下 20ns 数据窗口正中，修偶发错字节导致的彩条与音频电流声；卡模型补 15ns tODLY
- 上板修复（v22）：扫描窗口 64MB→128MB（`SCAN_MAX_SECTOR=262143`）。换卡后容器被拷到 LBA 143104，越出旧窗口且编译期回退地址已空 → `egv_reader` 判 `M_NONE` 拒播，面板 `FRAME 00000` + `V:NG`
- 布局布线：v22 seed 2（Flow22 单进程 RTL→bitgen）Setup +12ps / Hold +22ps / 0 FEPs，LUT 16861（86.03%）、9567 slices（97.62%）、54 RAM、21 DSP
- bit：`HDMI1.4b_Transmitter_v1.0_winscan_seed2_setup12_hold22.bit`，见 `../bitstream/README.md`；**已上板验证，功能全部正常**
- 剩余：演示收尾、技术报告定稿

## 文档索引

| 文档 | 说明 |
|---|---|
| [01-赛题要求](docs/01-赛题要求.md) | 比赛任务与评分 |
| [02-硬件平台](docs/02-硬件平台.md) | 板卡资源 |
| [03-系统架构](docs/03-系统架构.md) | 数据流、时钟域、模块 |
| [04-功能与操作](docs/04-功能与操作.md) | 操作与协议 |
| [05-验证记录](docs/05-验证记录.md) | 仿真、QoR、bit |
| [06-进度与迭代计划](docs/06-进度与迭代计划.md) | 完成度与下一步 |
| [07-TD 工程与 Multi-Seed](docs/07-TD工程与MultiSeed.md) | 重建流程 |
| [08-图片与 TF 卡制作](docs/08-图片与TF卡制作.md) | 素材制作 |
| [sim/README](sim/README.md) | 测试平台 |
| [tools/README](tools/README.md) | 辅助工具 |
