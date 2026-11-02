#!/usr/bin/env python3
"""区分音频扇区相位假设：≡0 (mod 12) vs ≡11 (mod 12)

用帧 100..102 的数据分别按两种假设重建音/视频流，比较统计特征：
  音频(s16le)：相邻样本差小、幅度平滑 → 正确假设
  视频(RGB565)：相邻像素差小 → 正确假设
错误假设会把视频字节当音频（差分统计剧烈）、音频字节当视频。
"""
import struct
import sys

sys.path.insert(0, r"C:\FPGA_projects\Contest\merged\tools\video")
from exfat_check import Reader

DRIVE = "F:"
BLOCK_SEC = 201
MOD = 12

r = Reader(DRIVE)
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

    def get_frame(f):
        base = l2p(f * BLOCK_SEC)
        return r.read(base * 512, BLOCK_SEC * 512)

    def audio_stats(blk, phase):
        # phase: 0 → s%12==0 为音频; 11 → s%12==11 为音频
        data = b"".join(blk[s*512:(s+1)*512] for s in range(BLOCK_SEC)
                        if s % MOD == phase)
        data = data[:8000]
        sm = struct.unpack("<%dh" % (len(data)//2), data[:len(data)//2*2])
        dif = [abs(sm[i+1]-sm[i]) for i in range(len(sm)-1)]
        peak = max(abs(x) for x in sm)
        avgd = sum(dif)/len(dif)
        return peak, avgd

    def video_stats(blk, phase):
        # 音频相位为 phase → 视频扇区 = s%12 != phase
        data = b"".join(blk[s*512:(s+1)*512] for s in range(BLOCK_SEC)
                        if s % MOD != phase)
        px = [(data[i] << 8) | data[i+1] for i in range(0, len(data)-1, 2)]
        dif = [abs(px[i+1]-px[i]) for i in range(len(px)-1)]
        return sum(dif)/len(dif), max(dif)

    for f in (100, 101, 200, 1000):
        blk = get_frame(f)
        p0, d0 = audio_stats(blk, 0)
        p11, d11 = audio_stats(blk, 11)
        v0, vm0 = video_stats(blk, 0)
        v11, vm11 = video_stats(blk, 11)
        print("frame %d:" % f)
        print("  audio if phase=0 : peak=%6d avg|ds|=%8.1f" % (p0, d0))
        print("  audio if phase=11: peak=%6d avg|ds|=%8.1f" % (p11, d11))
        print("  video if phase=0 : avg|dp|=%8.1f max=%5d" % (v0, vm0))
        print("  video if phase=11: avg|dp|=%8.1f max=%5d" % (v11, vm11))

    # 另一个铁证：音频区尾 192B 补零 + 其前应为有效音频（非全零）
    for f in (100, 101, 500, 1927):
        blk = get_frame(f)
        for cand in (180, 191, 192):
            tail = blk[cand*512+320:cand*512+512]
            head = blk[cand*512:cand*512+64]
            print("frame %d sector %3d: tail192 all-zero=%s  head64 all-zero=%s"
                  % (f, cand, tail == bytes(192), head == bytes(64)))
finally:
    r.close()
