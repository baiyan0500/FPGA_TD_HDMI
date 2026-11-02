// egv_audio_check.js — 从卡上容器原始字节里解出前 N 帧音频，判断是"正常波形"
// 还是"白噪声/错位/字节序反转"。用法：node egv_audio_check.js real_mem.hex [帧数]
'use strict';
const fs = require('fs');

const file = process.argv[2] || 'real_mem.hex';
const NF = parseInt(process.argv[3] || '2', 10);

const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/).filter(s => s.trim().length);
const mem = Buffer.alloc(lines.length);
for (let i = 0; i < lines.length; i++) mem[i] = parseInt(lines[i].trim(), 16) & 0xff;

// 文件内扇区偏移：帧0 从 1 开始；帧1 前 54 扇区从 202 开始，之后在 256 起（run1）
function frameSectors(f) {
    const out = [];
    for (let k = 0; k < 201; k++) {
        if (k % 12 === 11) {
            let off;
            if (f === 0) off = 1 + k;
            else if (f === 1) off = (k < 54) ? 202 + k : 256 + (k - 54);
            else return out;
            out.push(off);
        }
    }
    return out;
}

function stats(samples) {
    let mn = 32767, mx = -32768, sum = 0, diff = 0, zc = 0, prev = 0;
    for (let i = 0; i < samples.length; i++) {
        const v = samples[i];
        if (v < mn) mn = v;
        if (v > mx) mx = v;
        sum += v * v;
        if (i) diff += Math.abs(v - prev);
        if (i && ((v >= 0) !== (prev >= 0))) zc++;
        prev = v;
    }
    const rms = Math.sqrt(sum / samples.length);
    return { mn, mx, rms: rms.toFixed(1), meanDiff: (diff / Math.max(1, samples.length - 1)).toFixed(1), zcr: (zc / Math.max(1, samples.length - 1)).toFixed(3) };
}

for (let f = 0; f < NF; f++) {
    const secs = frameSectors(f);
    if (!secs.length) break;
    const bytes = [];
    for (const s of secs) {
        const base = s * 512;
        for (let p = 0; p < 512 && bytes.length < 8000; p++) bytes.push(mem[base + p]);
    }
    console.log(`\n=== frame ${f}: ${bytes.length} bytes, ${secs.length} audio sectors ===`);

    // 左侧/右侧按 little-endian 解 s16 立体声
    const L = [], R = [], Lsw = [], Rsw = [];
    for (let i = 0; i + 3 < bytes.length; i += 4) {
        L.push((bytes[i] | (bytes[i + 1] << 8)) << 16 >> 16);
        R.push((bytes[i + 2] | (bytes[i + 3] << 8)) << 16 >> 16);
        Lsw.push(((bytes[i] << 8) | bytes[i + 1]) << 16 >> 16);
        Rsw.push(((bytes[i + 2] << 8) | bytes[i + 3]) << 16 >> 16);
    }
    console.log('  L  little-endian:', JSON.stringify(stats(L)));
    console.log('  R  little-endian:', JSON.stringify(stats(R)));
    console.log('  L  byte-swapped :', JSON.stringify(stats(Lsw)));
    console.log('  R  byte-swapped :', JSON.stringify(stats(Rsw)));
    console.log('  前 8 个立体声对 (L,R) LE:', JSON.stringify(L.slice(0, 8).map((v, i) => [v, R[i]])));
    console.log('  L 前 16 字节 hex:', Buffer.from(bytes.slice(0, 16)).toString('hex'));
    // 全零比例（判断是否静音/补零）
    let nz = 0; for (const b of bytes) if (b) nz++;
    console.log(`  非零字节比例: ${(100 * nz / bytes.length).toFixed(1)}%`);
}
