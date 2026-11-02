#!/usr/bin/env python3
"""逐帧定位音频区尾 192B 补零所在的 block 内扇区号（无歧义的音频区终点签名）"""
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

    def pad_sector(f):
        base = l2p(f * 201)
        blk = r.read(base * 512, 201 * 512)
        hits = []
        for s in range(201):
            sec = blk[s*512:(s+1)*512]
            if sec[320:512] == bytes(192) and sec[0:64] != bytes(64):
                hits.append(s)
        return hits

    print("frame -> padding sector(s)")
    for f in list(range(0, 24)) + [48, 49, 50, 100, 101, 102, 500, 963, 964, 965, 1925, 1926, 1927]:
        print("  %4d -> %s" % (f, pad_sector(f)))
finally:
    r.close()
