"""按 egv_reader 的运行时逻辑精确复现一帧像素，验证是否存在固定横向错位。

关键：段表在帧头偏移 44 开始，每条 12B = (logical_lba, n_sectors, phys_lba)。
文件首扇区是 512B 头，不属于数据流 -> run0 的 phys+1 / nsec-1。
"""
import struct, sys
from PIL import Image

P = "F:/VIDEO.EGV"
W, H, MOD, BSEC = 320, 148, 12, 201
RUN_OFF = 44

f = open(P, "rb")
hdr = f.read(512)
nframes, block_bytes, video_bytes = struct.unpack_from("<III", hdr, 12)
audio_bytes, rate, ch, block_sectors = struct.unpack_from("<IHHH", hdr, 24)
audio_mod, total = struct.unpack_from("<HI", hdr, 34)
nruns, _ = struct.unpack_from("<HH", hdr, 40)

segs = []
for i in range(nruns):
    lg, nsec, phys = struct.unpack_from("<III", hdr, RUN_OFF + i * 12)
    segs.append((lg, nsec, phys))
print("frames", nframes, "block_sec", block_sectors, "audio_mod", audio_mod, "nruns", nruns)
for i, s in enumerate(segs):
    print("  seg%d logical=%d nsec=%d phys=%d" % (i, s[0], s[1], s[2]))

# 运行时：run0 跳过 512B 头
runs = []
for i, (lg, nsec, phys) in enumerate(segs):
    runs.append((phys + (1 if i == 0 else 0), nsec - (1 if i == 0 else 0)))

# 文件内扇区偏移 -> 数据（段内线性）
def sec_bytes(foff_sec):
    f.seek(foff_sec * 512)
    return f.read(512)

def lba_to_fileoff(lba):
    """把卡绝对 LBA 映射到文件内扇区偏移"""
    acc = 0
    for i, (lg, nsec, phys) in enumerate(segs):
        if phys <= lba < phys + nsec:
            return acc + (lba - phys)
        acc += nsec
    return None

def read_frame(start_lba, phys_base_onebased):
    """按 reader 的段推进逻辑读一帧 201 扇区，返回扇区列表"""
    phys = start_lba
    ri = 0
    rem = runs[0][1]
    # 定位起始所在的段
    while ri < len(runs) and not (runs[ri][0] <= phys < runs[ri][0] + runs[ri][1]):
        ri += 1
    if ri >= len(runs):
        return None
    rem = runs[ri][1] - (phys - runs[ri][0])
    out = []
    for s in range(BSEC):
        off = lba_to_fileoff(phys)
        if off is None:
            return None
        out.append(sec_bytes(off))
        phys += 1
        rem -= 1
        if rem == 0 and ri + 1 < len(runs):
            ri += 1
            phys = runs[ri][0]
            rem = runs[ri][1]
    return out

def render(sectors, name):
    vid = bytearray()
    for i, s in enumerate(sectors):
        if i % MOD == MOD - 1:
            continue
        vid += s
    need = W * H * 2
    if len(vid) < need:
        print("  !! video bytes short: %d < %d" % (len(vid), need))
        vid += bytes(need - len(vid))
    img = Image.new("RGB", (W, H))
    px = img.load()
    for y in range(H):
        for x in range(W):
            o = (y * W + x) * 2
            v = (vid[o] << 8) | vid[o + 1]
            r = (v >> 11) & 0x1F
            g = (v >> 5) & 0x3F
            b = v & 0x1F
            px[x, y] = (r << 3 | r >> 2, g << 2 | g >> 4, b << 3 | b >> 2)
    img.save(name)
    print("  wrote", name, "video bytes", len(vid))
    return vid

print("\n== 正确起点（run0 phys+1 = 数据流首扇区）==")
for fn in (0, 1, 2):
    # 帧起点 = 数据流逻辑第 fn*201 扇区
    lba = None
    acc = 0
    target = fn * BSEC
    for ri, (lg, nsec, phys) in enumerate(segs):
        base_off = phys + (1 if ri == 0 else 0)
        base_len = nsec - (1 if ri == 0 else 0)
        if acc <= target < acc + base_len:
            lba = base_off + (target - acc)
            break
        acc += base_len
    if lba is None:
        print("frame", fn, "out of range"); continue
    secs = read_frame(lba, True)
    if secs is None:
        print("frame", fn, "read failed"); continue
    print("frame %d start_lba %d" % (fn, lba))
    render(secs, "rf_f%d.png" % fn)

print("\n== 错误起点（直接用 phys=47360，含头扇区，即 -1 偏移）==")
for fn in (0, 1):
    secs = read_frame(segs[0][2] + fn * BSEC, False)
    if secs is None:
        print("bad frame", fn); continue
    print("frame %d start_lba %d" % (fn, segs[0][2] + fn * BSEC))
    render(secs, "rw_f%d.png" % fn)
