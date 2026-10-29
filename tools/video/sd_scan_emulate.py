#!/usr/bin/env python3
"""模拟 bmp_read.v 的上电扫描（4KB 步进 / BMP 跳转 / WAV 跳转）

用途：在 PC 上复现固件的扫描顺序，确认某张 BMP / 某个 WAV 会不会被扫到，
以及是哪一步让扫描提前结束（16 张上限、scan_max_sector、假 BMP 长跳）。

用法: python sd_scan_emulate.py F:
"""
import struct
import sys
import time

from exfat_check import Reader

SCAN_START = 0
SCAN_MAX = 131071
SCAN_STEP = 8
TARGET = 16


def main():
    drive = sys.argv[1] if len(sys.argv) > 1 else "F:"
    r = Reader(drive)
    t0 = time.time()
    sec = SCAN_START
    found, wav_found, wav_sector = [], False, None
    stop_reason = "scan_max_sector"
    reads = 0
    trace = []
    while True:
        d = r.read(sec * 512, 512)
        reads += 1
        if len(d) < 512:
            stop_reason = "short read at %d" % sec
            break
        file_len = struct.unpack_from("<I", d, 2)[0]
        pix_off = struct.unpack_from("<I", d, 10)[0]
        width = struct.unpack_from("<i", d, 18)[0]
        height = struct.unpack_from("<i", d, 22)[0]
        bitc = struct.unpack_from("<H", d, 28)[0]
        comp = struct.unpack_from("<I", d, 30)[0]
        hdr_ok = (d[0:1] == b"B" and d[1:2] == b"M" and bitc == 24 and comp == 0
                  and width != 0 and width <= 1024
                  and height != 0 and 0 < height <= 2047
                  and file_len > pix_off)
        wav_ok = d[0:4] == b"RIFF" and d[8:12] == b"WAVE"
        riff_size = struct.unpack_from("<I", d, 4)[0]

        if hdr_ok:
            found.append((sec, width, height, file_len))
            trace.append((sec, "BMP %dx%d len=%d" % (width, height, file_len)))
            nxt = sec + ((file_len + 511) >> 9)
            if (len(found) >= TARGET and wav_found) or nxt > SCAN_MAX:
                stop_reason = ("target reached w/ wav" if len(found) >= TARGET
                               else "BMP jump past scan_max")
                sec = nxt
                break
            sec = nxt
        elif wav_ok:
            if not wav_found:
                wav_found, wav_sector = True, sec
                trace.append((sec, "WAV riff_size=%d" % riff_size))
            else:
                trace.append((sec, "WAV(again)"))
            nxt = sec + ((riff_size + 8 + 511) >> 9)
            if len(found) >= TARGET:
                stop_reason = "target reached w/ wav"
                break
            sec = nxt
        else:
            if sec >= SCAN_MAX:
                break
            sec = (sec + SCAN_STEP) & 0xFFFFFFF8

    dt = time.time() - t0
    print("reads=%d  elapsed=%.1fs  final_sector=%d  stop=%s"
          % (reads, dt, sec, stop_reason))
    print("BMP matches: %d" % len(found))
    for s, w, h, ln in found:
        print("  lba %7d  %4dx%-4d len %d" % (s, w, h, ln))
    if wav_found:
        print("WAV start sector: %d" % wav_sector)
    else:
        print("WAV: NOT FOUND")
    for s, msg in trace:
        if not msg.startswith("BMP"):
            print("  trace lba %d: %s" % (s, msg))
    r.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
