# 辅助工具

## gen_font.js

生成 `src/user_source/hdl_source/osd/font8x8.v` 的 8×8 ASCII 字模，并在终端打印预览。

```bash
node tools/gen_font.js
```

修改字模后需重新综合。

## docx2md

把 `.docx` 转为 Markdown（含图片提取），用于整理厂商文档。

```bash
cd tools/docx2md
npm install
node docx2md.js ../../doc/APUG092_HDMI1.4b_Transmitter_V1.0.docx -o /tmp/out.md
```

依赖未入库，首次使用需 `npm install`。

## video/mp4_to_egv.py

把 mp4 转成 FPGA 顺序读取的 EGV1 容器（320×148 RGB565 + 48kHz s16 立体声），并按实际物理段回填 `src/user_source/hdl_source/video/egv_cfg.vh`。需要 `imageio-ffmpeg`（`pip install imageio-ffmpeg`），读取 exFAT 物理段需要管理员权限。

```bash
python tools/video/mp4_to_egv.py input.mp4 E:/VIDEO.EGV
# 可选：--width 320 --height 148 --fps 24 --rate 48000
```

容器头部记录每段的物理 LBA，**换视频后必须重新综合**。

## video/exfat_check.py

检查 TF 卡上大文件（如 EGV 容器、BMP 序列）的物理簇连续性，碎片过多时 FPGA 顺序读会错位。

```bash
python tools/video/exfat_check.py E:
```
