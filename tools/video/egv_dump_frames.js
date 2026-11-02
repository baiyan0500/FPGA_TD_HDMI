// egv_dump_frames.js — 从 EGV 容器里解出指定帧为 PPM（RGB565 大端，320×148）
// 用法：node egv_dump_frames.js VIDEO.EGV out_prefix 0,100,399,400
'use strict';
const fs = require('fs');
const [, , egvPath, prefix, list] = process.argv;
const W = 320, H = 148, BS = 201 * 512;
const frames = (list || '0').split(',').map(Number);
const fd = fs.openSync(egvPath, 'r');
const blk = Buffer.alloc(BS);
const pix = Buffer.alloc(W * H * 2);
for (const f of frames) {
    fs.readSync(fd, blk, 0, BS, 512 + f * BS);
    let vp = 0;
    for (let s = 0; s < 201; s++) {
        if (s % 12 === 11) continue;
        blk.copy(pix, vp, s * 512, s * 512 + 512);
        vp += 512;
    }
    const rgb = Buffer.alloc(W * H * 3);
    for (let i = 0; i < W * H; i++) {
        const v = (pix[2 * i] << 8) | pix[2 * i + 1];   // big-endian RGB565
        const r = (v >> 11) & 0x1f, g = (v >> 5) & 0x3f, b = v & 0x1f;
        rgb[3 * i] = (r * 255 / 31) | 0;
        rgb[3 * i + 1] = (g * 255 / 63) | 0;
        rgb[3 * i + 2] = (b * 255 / 31) | 0;
    }
    const out = `${prefix}_${f}.ppm`;
    fs.writeFileSync(out, Buffer.concat([Buffer.from(`P6\n${W} ${H}\n255\n`), rgb]));
    // 粗统计：平均色、纯色行数（判断是否彩条）
    let sr = 0, sg = 0, sb = 0;
    for (let i = 0; i < W * H; i++) { sr += rgb[3 * i]; sg += rgb[3 * i + 1]; sb += rgb[3 * i + 2]; }
    console.log(`frame ${f} -> ${out}  avg RGB ${(sr / W / H) | 0},${(sg / W / H) | 0},${(sb / W / H) | 0}`);
}
fs.closeSync(fd);
