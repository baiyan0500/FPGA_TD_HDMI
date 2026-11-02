#!/usr/bin/env python3
"""在逻辑扇区流上扫描音频区尾补零签名，测每块实际长度与音频相位演化"""
import struct
import sys

sys.path.insert(0, r"C:\FPGA_projects\Contest\merged\tools\video")
from exfat_check import Reader

r = Reader("F:")
try:
    hdr = r.read(47360 * 512, 512)
    n_runs = struct.unpack_from("<H", hdr, 40)[0]
    runs = [struct.unpack_from("<III", hdr, 44 + 12 * i) for i in range(4)]

    def l2p(logical):
        for i, (lg, ns, ph) in enumerate(runs[:n_runs]):
            n_data = ns - (1 if i == 0 else 0)
            if lg <= logical < lg + n_data:
                return ph + (1 if i == 0 else 0) + (logical - lg)
        return None

    # 扫逻辑 0..45225 (前225块) 的物理连续区间，逐扇区找签名
    # run0: logical 0..254 连续；run1: 256..385279 连续（跳过255不存在? 逻辑255在run0? 
    # run0 nsec=256 含头 → 数据 0..254; run1 logical 从 256 起）
    LOG0, NSEC = 0, 45225
    # 逐块读（跨段处逻辑地址不连续，需逐扇区映射；先在 run0+run1 连续大区间读）
    base = l2p(LOG0)
    assert base is not None
    data = r.read(base * 512, 255 * 512)          # run0 数据 0..254
    base1 = l2p(256)
    assert base1 is not None
    # run1 长 385024 扇区，一次读 45000 个
    data += r.read(base1 * 512, (NSEC - 256) * 512)

    print("sig at logical sector (block-relative, frame#):")
    prev = None
    for s in range(0, NSEC - 1):
        sec = data[s*512:(s+1)*512]
        if sec[320:512] == bytes(192) and sec[0:64] != bytes(64):
            if prev is not None:
                blk_len = s - prev
                frame = s // 201
                rel = s % 201
                print("  logical %6d  frame~%4d  rel=%3d  block_len=%d" %
                      (s, frame, rel, blk_len))
            else:
                print("  logical %6d  frame~%4d  rel=%3d  (first)" %
                      (s, s // 201, s % 201))
            prev = s
finally:
    r.close()
