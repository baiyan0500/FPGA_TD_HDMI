# EG4S20 HDMI 多媒体播放器（主工程）

基于安路 EG4S20BG256（HX4S20C）的纯 FPGA HDMI 音视频播放系统。TF 卡 BMP 图片经 SDRAM 双缓冲送 HDMI 显示，WAV 音频经 ASRC 与 I2S 嵌入 HDMI，叠加 OSD、转场、频谱与按键交互；TF 卡上另存一段 EGV 视频容器，可在视频层播放 320×148@24fps 画面与音轨。

## 功能清单

| 分类 | 功能 |
|---|---|
| 图片 | TF 卡 BMP 扫描（前 64MB、4KB 步进、最多 16 张）、任意分辨率≤1024×2047 最近邻缩放、双缓冲切换、手动/自动轮播 |
| 视频 | 640×480@60、HDMI 1.4b、25MHz 像素时钟；EGV 容器视频（320×148@24fps + 48kHz 音轨）2 倍放大居中播放 |
| 音频 | WAV 16bit PCM、单/双声道、8k~48k、ASRC→48k、HDMI 音频、循环/暂停、测试音回退 |
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
- 根目录放 WAV：16bit PCM、单/双声道、8k~48k（取扫描到的第一个 WAV，循环播放）
- 根目录放 EGV 视频容器（可选）：用 `tools/video/mp4_to_egv.py` 生成；换视频须重新综合
- FAT32 / exFAT 均可；使用 `doc/convert/sync_to_sd.py` 同步，避免物理扇区残留旧图

详见 [图片与 TF 卡制作](docs/08-图片与TF卡制作.md)。

### 3. 上板操作

按键/拨码映射、UART 标语协议见 [功能与操作](docs/04-功能与操作.md)。

## 当前状态（2026-10-29）

- 功能：基础 4/4、扩展 5/5 均已实现；本轮新增三层按键重规划、视频播放、弹幕、资源面板
- 官方布局布线：Multi-Seed seed 2 完成，Setup +557ps / Hold +21ps / 0 FEPs，LUT 14057（71.72%）、8385 slices（85.56%）、54 RAM、19 DSP
- bit：`HDMI1.4b_Transmitter_v1.0_video_seed2_setup557_hold21.bit`，见 `../bitstream/README.md`；待上板回归
- 剩余：上板验证、演示收尾

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
