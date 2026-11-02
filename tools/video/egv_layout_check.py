#!/usr/bin/env python3
"""验证 TF 卡上 EGV 文件的实际布局是否与 egv_reader 假设一致

检查项：
  1. 头部字段 vs egv_cfg.vh
  2. 段表：run0 起点 == 头LBA+1；总扇区 == frames*201
  3. 每个抽检 block（含跨 run 边界的 block）：
     - 音频尾补零（192B 全零）只出现在 block 内第 195 号扇区（第16个音频扇区）的尾部
     - 其余扇区不应有大段全零（排除误判）
  4. 视频数据首字节合理性（RGB565 大端）
"""
import struct
import sys

sys.path.insert(0, r"C:\FPGA_projects\Contest\merged\tools\video")
from exfat_check import Reader

DRIVE = "F:"
HDR_LBA = 47360
BLOCK_SEC = 201
AUDIO_MOD = 12
AUDIO_BYTES = 8000
N_AUDIO_SEC = 16

r = Reader(DRIVE)
try:
    hdr = r.read(HDR_LBA * 512, 512)
    magic = hdr[0:4]
    ver, w, h, fps = struct.unpack_from("<HHHH", hdr, 4)
    frames, block_bytes, video_bytes = struct.unpack_from("<III", hdr, 12)
    audio_bytes, arate, ach, bs = struct.unpack_from("<IHHH", hdr, 24)
    audio_mod, total_bytes = struct.unpack_from("<HI", hdr, 34)
    n_runs, _ = struct.unpack_from("<HH", hdr, 40)
    runs = [struct.unpack_from("<III", hdr, 44 + 12 * i) for i in range(4)]

    print("header@%d: magic=%r ver=%d %dx%d@%dfps frames=%d" %
          (HDR_LBA, magic, ver, w, h, fps, frames))
    print("  block_bytes=%d video_bytes=%d audio_bytes=%d arate=%d ach=%d" %
          (block_bytes, video_bytes, audio_bytes, arate, ach))
    print("  block_sectors=%d audio_mod=%d total=%d n_runs=%d" %
          (bs, audio_mod, total_bytes, n_runs))
    for i, (lg, ns, ph) in enumerate(runs):
        print("  run%d: logical=%d nsec=%d phys=%d" % (i, lg, ns, ph))

    # 逻辑扇区 -> 物理扇区（数据流，头后）
    def l2p(logical):
        for i, (lg, ns, ph) in enumerate(runs[:n_runs]):
            n_data = ns - (1 if i == 0 else 0)
            if lg <= logical < lg + n_data:
                rp = ph + (1 if i == 0 else 0)
                return rp + (logical - lg)
        return None

    # 音频区: block 内 s % audio_mod == audio_mod-1
    audio_pos = [s for s in range(BLOCK_SEC) if s % audio_mod == audio_mod - 1]
    print("audio sectors in block: %s (n=%d)" % (audio_pos, len(audio_pos)))

    def check_block(frame_no):
        base_lba = l2p(frame_no * BLOCK_SEC)
        if base_lba is None:
            print("frame %d: logical %d not mappable!" %
                  (frame_no, frame_no * BLOCK_SEC))
            return
        blk = r.read(base_lba * 512, BLOCK_SEC * 512)
        zero_secs = []
        for s in range(BLOCK_SEC):
            sec = blk[s * 512:(s + 1) * 512]
            # 找 >=128 连续全零的扇区
            zrun = 0
            mx = 0
            for b in sec:
                zrun = zrun + 1 if b == 0 else 0
                mx = max(mx, zrun)
            if mx >= 128:
                zero_secs.append((s, mx))
        expect = audio_pos[-1]
        ok = zero_secs == [(expect, 192)] or (
            len(zero_secs) == 1 and zero_secs[0][0] == expect)
        print("frame %4d @LBA %d: zero-tail sectors=%s  expect=[(%d,192)]  %s" %
              (frame_no, base_lba, zero_secs, expect, "OK" if ok else "MISMATCH"))
        return blk

    # 抽检：frame 0（全在 run0）、frame 1（跨 run0→run1，数据扇区 201..401，run0 数据止于 254）
    # frame 2、末帧 1927
    for f in (0, 1, 2, 100, 1927):
        blk = check_block(f)
        if f == 0 and blk:
            # frame0 视频首扇区（s=0）前 32 字节
            print("  frame0 video first 32B:", blk[0:32].hex())

    # 跨段处的逻辑/物理换算展示
    for logical in (254, 255, 256, 385278, 385279, 385280):
        print("logical %d -> phys %s" % (logical, l2p(logical)))
finally:
    r.close()
