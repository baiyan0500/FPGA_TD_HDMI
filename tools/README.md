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
