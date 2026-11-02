#!/usr/bin/env node
// ppm2png — 把 P6 二进制 PPM 转成 PNG（无第三方依赖，仅用 Node 内置 zlib）
// 用法：node ppm2png.js in.ppm out.png
'use strict';
const fs = require('fs');
const zlib = require('zlib');

const [, , inPath, outPath] = process.argv;
if (!inPath || !outPath) {
  console.error('usage: node ppm2png.js in.ppm out.png');
  process.exit(1);
}

const buf = fs.readFileSync(inPath);

// ---- 解析 P6 头（magic / width / height / maxval，允许 # 注释）----
let pos = 0;
function token() {
  while (pos < buf.length) {
    const c = buf[pos];
    if (c === 0x23) {                       // '#'
      while (pos < buf.length && buf[pos] !== 0x0a) pos++;
    } else if (c === 0x20 || c === 0x0a || c === 0x0d || c === 0x09) {
      pos++;
    } else break;
  }
  const start = pos;
  while (pos < buf.length && ![0x20, 0x0a, 0x0d, 0x09].includes(buf[pos])) pos++;
  return buf.slice(start, pos).toString('ascii');
}
if (token() !== 'P6') throw new Error('not a P6 PPM');
const width = parseInt(token(), 10);
const height = parseInt(token(), 10);
const maxval = parseInt(token(), 10);
pos++;                                       // 头部后单个空白

if (maxval !== 255) throw new Error('only maxval 255 supported');
const data = buf.slice(pos);
if (data.length < width * height * 3) {
  throw new Error(`truncated pixel data: ${data.length} < ${width * height * 3}`);
}

// ---- PNG 组装 ----
function crc32(b) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < b.length; n++) {
    c = (crc ^ b[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type, body) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(body.length, 0);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), body]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td), 0);
  return Buffer.concat([len, td, crc]);
}

const raw = Buffer.alloc((width * 3 + 1) * height);
for (let y = 0; y < height; y++) {
  raw[y * (width * 3 + 1)] = 0;              // filter: none
  data.copy(raw, y * (width * 3 + 1) + 1, y * width * 3, (y + 1) * width * 3);
}

const ihdr = Buffer.alloc(13);
ihdr.writeUInt32BE(width, 0);
ihdr.writeUInt32BE(height, 4);
ihdr[8] = 8;                                 // bit depth
ihdr[9] = 2;                                 // color type: RGB

const png = Buffer.concat([
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
  chunk('IHDR', ihdr),
  chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
  chunk('IEND', Buffer.alloc(0)),
]);

fs.writeFileSync(outPath, png);
console.log(`${outPath}  ${width}x${height}`);
