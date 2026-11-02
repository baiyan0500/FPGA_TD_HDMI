#!/usr/bin/env node
// ============================================================================
// egv_locate.js — 查 TF 卡上 VIDEO.EGV 的物理位置，判断是否落在 FPGA 扫描窗口内
//
// FPGA 不带文件系统驱动，靠"每 4KB 读 1 个扇区"扫魔数定位 BMP/WAV/EGV。
// 扫描窗口 = SCAN_MAX_SECTOR（当前 262143 扇区 = 128MB）。容器一旦被拷贝到
// 窗口之外，就只剩编译期 EGV_BASE_LBA 回退；那里若已不含 EGV1 头，
// egv_reader 会判 M_NONE 拒播（面板 FRAME 00000 + V:NG），黑屏且不出声。
//
// 用法（需要管理员权限读物理盘）：
//   node egv_locate.js <物理盘号> [文件名]
//   node egv_locate.js 1 VIDEO.EGV
//
// 输出：卷引导参数、文件起始簇/物理 LBA、物理段数、是否连续、
//       是否在扫描窗口内、头内段表是否与当前物理位置一致。
// ============================================================================
'use strict';

const fs = require('fs');

const WIN = 262143;                    // SCAN_MAX_SECTOR（top_tf_hdmi_audio.v）
const SECTOR = 512;

const drv = process.argv[2];
const fname = process.argv[3] || 'VIDEO.EGV';
if (!drv) {
    console.log('usage: node egv_locate.js <PhysicalDriveN> [VIDEO.EGV]');
    process.exit(2);
}

const devPath = '\\\\.\\PhysicalDrive' + drv;
let fd;
try {
    fd = fs.openSync(devPath, 'r');
} catch (e) {
    console.error('打不开 ' + devPath + '（需要管理员权限）: ' + e.message);
    process.exit(1);
}

function rd(lba, n) {
    const b = Buffer.alloc(n * SECTOR);
    const got = fs.readSync(fd, b, 0, b.length, lba * SECTOR);
    return b.subarray(0, got);
}

// ---------------- 分区表：找第一个非空分区 ----------------
const mbr = rd(0, 1);
let partLba = 0;
if (mbr[510] === 0x55 && mbr[511] === 0xAA) {
    for (let i = 0; i < 4; i++) {
        const o = 446 + i * 16;
        const type = mbr[o + 4];
        const lba = mbr.readUInt32LE(o + 8);
        if (type !== 0 && lba !== 0) { partLba = lba; break; }
    }
    console.log('MBR 分区起始 LBA = ' + partLba + '（' + (partLba / 2048).toFixed(1) + 'MB）');
} else {
    console.log('无 MBR（superfloppy），卷从 LBA 0 开始');
}

// ---------------- exFAT 引导参数 ----------------
const bs = rd(partLba, 1);
if (bs.slice(3, 11).toString() !== 'EXFAT   ') {
    console.error('卷不是 exFAT（实际签名: ' + JSON.stringify(bs.slice(3, 11).toString()) + '）');
    process.exit(1);
}
const fatOff   = bs.readUInt32LE(0x50);
const heapOff  = bs.readUInt32LE(0x58);
const rootClu  = bs.readUInt32LE(0x60);
const spcShift = bs[0x6D];
const spc      = 1 << spcShift;        // 每簇扇区数
const cluLba   = c => partLba + heapOff + (c - 2) * spc;

console.log(`exFAT: FAT@${partLba + fatOff}  簇堆@${partLba + heapOff}  根目录簇=${rootClu}  簇大小=${spc}扇区(${spc * 512 / 1024}KB)`);

// ---------------- 根目录找文件 ----------------
const root = rd(cluLba(rootClu), spc);
let found = null;
for (let off = 0; off + 32 <= root.length;) {
    const t = root[off];
    if (t === 0x00) break;
    if (t === 0x85) {
        const sec = root[off + 1];
        let name = '', first = 0, len = 0n;
        for (let k = 1; k <= sec; k++) {
            const e = off + 32 * k;
            if (root[e] === 0xC0) {
                const nl = root[e + 3];
                first = root.readUInt32LE(e + 20);
                len = root.readBigUInt64LE(e + 24);
                for (let j = 1; j <= sec; j++) {
                    const f = off + 32 * j;
                    if (root[f] === 0xC1)
                        for (let p = 2; p < 32; p += 2) name += String.fromCharCode(root.readUInt16LE(f + p));
                }
                name = name.substring(0, nl);
            }
        }
        if (name.toUpperCase() === fname.toUpperCase()) { found = { name, first, len }; break; }
        off += 32 * (sec + 1);
        continue;
    }
    if (t >= 0x80 && t <= 0x9F) { off += 32 * (root[off + 1] + 1); continue; }
    off += 32;
}

if (!found) { console.error('根目录下没找到 ' + fname); process.exit(1); }
const nsec = Math.ceil(Number(found.len) / SECTOR);
console.log(`${found.name}: 大小 ${found.len} 字节 = ${nsec} 扇区，起始簇 ${found.first} → LBA ${cluLba(found.first)}`);

// ---------------- 读 FAT 链，统计物理段 ----------------
// FAT 表按扇区读（裸设备只接受整扇区读），128 项/扇区，带一格缓存
const fatBase = partLba + fatOff;
let fatCacheLba = -1, fatCache = null;
function fatEnt(c) {
    const lba = fatBase + ((c * 4) >> 9);
    if (lba !== fatCacheLba) { fatCache = rd(lba, 1); fatCacheLba = lba; }
    return fatCache.readUInt32LE((c * 4) & 511);
}
const needClu = Math.ceil(nsec / spc);
const runs = [];
let cur = found.first, runStart = cur, runLen = 1;
for (let i = 1; i < needClu; i++) {
    const nx = fatEnt(cur);
    if (nx === cur + 1) { runLen++; }
    else { runs.push({ start: runStart, len: runLen }); runStart = nx; runLen = 1; }
    cur = nx;
}
runs.push({ start: runStart, len: runLen });

console.log(`物理段数 = ${runs.length}`);
for (const r of runs) console.log(`  簇 ${r.start}..${r.start + r.len - 1} → LBA ${cluLba(r.start)}..${cluLba(r.start) + r.len * spc - 1}`);
const contiguous = runs.length === 1;

// ---------------- 头扇区校验 ----------------
const hdr = rd(cluLba(found.first), 1);
const magic = hdr.slice(0, 4).toString('latin1');
console.log(`头扇区魔数 = ${JSON.stringify(magic)}`);
const nRuns = hdr.readUInt16LE(40);
const hdrRuns = [];
for (let i = 0; i < Math.min(nRuns, 8); i++) {
    const o = 44 + i * 12;
    if (o + 12 > SECTOR) break;
    hdrRuns.push({ logical: hdr.readUInt32LE(o), nsec: hdr.readUInt32LE(o + 4), phys: hdr.readUInt32LE(o + 8) });
}
console.log(`头内段表 n_runs=${nRuns}`);
for (const r of hdrRuns) console.log(`  logical ${r.logical}  nsec ${r.nsec}  phys ${r.phys}`);
const hdrMatches = hdrRuns.length > 0 && hdrRuns[0].phys === cluLba(found.first);

// ---------------- 判定 ----------------
const lba0 = cluLba(found.first);
console.log('');
console.log('==== 判定 ====');
console.log(`起始 LBA ${lba0}（${(lba0 * 512 / 1048576).toFixed(1)}MB）  扫描窗口 ${WIN}（${(WIN * 512 / 1048576).toFixed(0)}MB）`);
console.log(`  4KB 对齐: ${lba0 % 8 === 0 ? '是（扫描步进能命中）' : '否！扫描步进 8 扇区会跳过它'}`);
console.log(`  在窗口内: ${lba0 <= WIN ? '是' : '否 → egv_found=0，会回退编译期 LBA'}`);
console.log(`  物理连续: ${contiguous ? '是（M_CONTIG 回退可用）' : '否（必须依赖头内段表，建议重新封装）'}`);
console.log(`  头内段表指向当前位置: ${hdrMatches ? '是（M_RT）' : '否（用 M_CONTIG；要求文件连续）'}`);
fs.closeSync(fd);
