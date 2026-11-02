#!/usr/bin/env python3
"""egv_video_geo — 检查 TF 卡 EGV 文件内视频画面是否横向回卷/错位

原理：自然视频相邻两行在"零滞后"处最相似。若 muxer 转换时把每行
循环移位了 k 个像素，则相邻行比较在滞后 k 处才最相似。
对多个帧、多对相邻行求 |diff|，比较 lag=0 与若干候选滞后。

用法: python egv_video_geo.py F:
"""
import sys
import ctypes
import struct

sys.path.insert(0, r"C:\FPGA_projects\Contest\merged\tools\video")
from exfat_check import file_info, Reader  # noqa: E402

W, H = 320, 148
BLOCK = 201
AMOD = 12
FRAMES = 1928

SEGS = [(0,   255,    47361),      # (data_logical_start, nsec, phys_start)
        (255, 385024, 513280),
        (385279, 2249, 905216)]


def phys_of(g):
    for start, n, p in SEGS:
        if start <= g < start + n:
            return p + (g - start)
    raise ValueError(g)


def sector_bytes(r, phys):
    return r.read(phys * 512, 512)


def video_bytes_of_frame(r, f):
    """返回该帧全部视频字节（185 扇区，按流顺序）"""
    out = b""
    base = f * BLOCK
    for s in range(BLOCK):
        if s % AMOD == AMOD - 1:
            continue
        out += sector_bytes(r, phys_of(base + s))
    return out


def row_of(vb, r):
    return vb[r * W * 2:(r + 1) * W * 2]


def pix_at(row, c):
    return (row[c * 2] << 8) | row[c * 2 + 1]


def main():
    drive = sys.argv[1] if len(sys.argv) > 1 else "F:"
    r = Reader(drive)
    try:
        lags = [0, 40, 80, 160, -80, -160]
        print("frame  rows | " + " | ".join("lag%+d" % l for l in lags))
        for f in [60, 300, 963, 1500]:
            vb = video_bytes_of_frame(r, f)
            acc = [0] * len(lags)
            pairs = 0
            for rr in range(20, 120, 10):
                ra, rb = row_of(vb, rr), row_of(vb, rr + 1)
                if not any(ra) or not any(rb):
                    continue  # 黑场帧跳过
                pairs += 1
                for li, lag in enumerate(lags):
                    d = 0
                    for c in range(W):
                        pa = pix_at(ra, c)
                        pb = pix_at(rb, (c + lag) % W)
                        d += abs((pa >> 11) - (pb >> 11))   # R 5bit 差
                        d += abs(((pa >> 5) & 0x3F) - ((pb >> 5) & 0x3F))
                        d += abs((pa & 0x1F) - (pb & 0x1F))
                    acc[li] += d
            if pairs:
                print("f%-5d %2d    | %s   (min=lag%+d)"
                      % (f, pairs,
                         " | ".join("%9d" % a for a in acc),
                         lags[acc.index(min(acc))]))
            else:
                print("f%-5d 全黑帧" % f)

        # 帧间（时间上）相关性：同位置像素相邻帧应最相似（检测帧错位）
        print()
        print("frame pair | same-pos diff | shift80 diff | shift1pix diff")
        for f in [500, 963]:
            v0 = video_bytes_of_frame(r, f)
            v1 = video_bytes_of_frame(r, f + 1)
            r0, r1 = row_of(v0, 70), row_of(v1, 70)
            d0 = sum(abs(pix_at(r0, c) - pix_at(r1, c)) for c in range(W))
            d80 = sum(abs(pix_at(r0, c) - pix_at(r1, (c + 80) % W)) for c in range(W))
            # 字节内高低错位（配对失败）时的伪差
            d1 = sum(abs((pix_at(r0, c) << 8 | pix_at(r0, c) >> 8) - pix_at(r1, c)) & 0xFFFF
                     for c in range(W))
            print("f%d/f%d  | %13d | %12d | %14d" % (f, f + 1, d0, d80, d1))
    finally:
        r.close()


if __name__ == "__main__":
    main()
