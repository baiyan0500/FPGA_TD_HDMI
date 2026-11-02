#!/usr/bin/env python3
"""mp4 -> EGV1 裸流容器（供 FPGA 顺序播放）

容器格式 v2（小端），头部 512B：
   0  'EGV1'      4  u16 ver=2     6  u16 w         8  u16 h
  10  u16 fps     12  u32 frames   16  u32 block_bytes
  20  u32 video_bytes              24  u32 audio_bytes
  28  u16 arate   30  u16 ach      32  u16 block_sectors
  34  u16 audio_mod                36  u32 total_bytes
  40  u16 n_runs  42  u16 reserved
  44  run[8] : u32 logical_lba, u32 n_sectors, u32 phys_lba   (12B/段)

每帧一个 block（block_sectors 个 512B 扇区）：扇区号 i 满足
i % audio_mod == audio_mod-1 时属于音频区，其余属于视频区；
两路各自顺序填充，块尾补零。

段表说明：exFAT 上 200MB 级文件常被拆成数段，FPGA 按裸扇区顺序读，
因此写入完成后回读 FAT 链，把物理段表回填进头部（需要管理员权限读卷）。

视频：RGB565 大端（高字节在前），w*h 像素，逐行从上到下。
音频：s16le 交织 L/R，每帧恰好 arate/fps 个立体声样本。
"""
import argparse
import os
import struct
import subprocess
import sys

import imageio_ffmpeg

import exfat_check

SECTOR = 512
MAX_RUNS = 4  # 与 egv_reader 运行时段表深度一致（超过 4 段的文件在 RTL 侧按连续回退处理）
RUN_OFF = 44


CFG_VH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                      "..", "..", "src", "user_source", "hdl_source",
                      "video", "egv_cfg.vh")


def ffmpeg_exe():
    return imageio_ffmpeg.get_ffmpeg_exe()


def write_cfg_vh(path, w, h, fps, frames, base_lba, block_sectors, audio_mod,
                 audio_bytes, segs):
    """把布局常量写成 RTL 可 include 的宏文件（数据流首扇区 = 文件首扇区 + 1）"""
    n = min(len(segs), MAX_RUNS)
    lines = [
        "// ============================================================================",
        "// egv_cfg.vh — EGV1 视频容器布局常量",
        "//",
        "// 【自动生成，请勿手改】由 tools/video/mp4_to_egv.py 在封装视频后回填。",
        "// 段表来自 exFAT 实际物理分布：TF 卡上 200MB 级文件必然分段，",
        "// FPGA 按裸扇区顺序读，必须知道每一段的物理起点。",
        "//",
        "// 若更换视频，重跑 mp4_to_egv.py 会覆写本文件，然后重新综合。",
        "// ============================================================================",
        "`define EGV_W             %d" % w,
        "`define EGV_H             %d" % h,
        "`define EGV_FPS           %d" % fps,
        "`define EGV_FRAMES        %d" % frames,
        "`define EGV_BASE_LBA      %d" % base_lba,
        "`define EGV_BLOCK_SECTORS %d" % block_sectors,
        "`define EGV_AUDIO_MOD     %d" % audio_mod,
        "`define EGV_AUDIO_BYTES   %d" % audio_bytes,
        "`define EGV_VIDEO_BYTES   %d" % (w * h * 2),
        "`define EGV_NRUNS         %d" % n,
        "",
        "// 每段：数据流逻辑起始扇区（累加值）与对应物理 LBA。",
        "// 文件首扇区是 512B 头，不属于数据流，故 RP0 = 文件起始 LBA + 1，",
        "// 且第一段的数据扇区数比物理段长少 1（RG1 = 段0 扇区数 - 1）。",
    ]
    dlog = 0                       # 数据流逻辑扇区累计
    slots = 4                      # egv_reader 只比较 3 个边界，最多 4 段
    for i in range(slots):
        if i < n:
            _lg, nsec, phys = segs[i]
            rp = phys + (1 if i == 0 else 0)
            lines.append("`define EGV_RG%d %d" % (i, dlog))
            lines.append("`define EGV_RP%d %d" % (i, rp))
            dlog += nsec - (1 if i == 0 else 0)
        else:
            if i == len(segs):
                lines.append("// 不足 %d 段时用哨兵值，RTL 的比较自然不成立"
                             % slots)
            lines.append("`define EGV_RG%d 32'hFFFFFFFF" % i)
            lines.append("`define EGV_RP%d 32'hFFFFFFFF" % i)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    print("wrote %s" % os.path.normpath(path))


def video_frames(path, w, h, fps):
    cmd = [ffmpeg_exe(), "-v", "error", "-i", path,
           "-vf", "scale=%d:%d:flags=area,fps=%d,format=rgb565be" % (w, h, fps),
           "-f", "rawvideo", "-pix_fmt", "rgb565be", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    fsz = w * h * 2
    while True:
        buf = proc.stdout.read(fsz)
        if len(buf) < fsz:
            break
        yield buf
    proc.stdout.close()
    proc.wait()


def audio_pcm(path, rate):
    cmd = [ffmpeg_exe(), "-v", "error", "-i", path, "-vn", "-ac", "2",
           "-ar", str(rate), "-f", "s16le", "-"]
    return subprocess.run(cmd, stdout=subprocess.PIPE, check=True).stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--width", type=int, default=320)
    ap.add_argument("--height", type=int, default=148)
    ap.add_argument("--fps", type=int, default=24)
    ap.add_argument("--rate", type=int, default=48000)
    args = ap.parse_args()

    w, h, fps, rate = args.width, args.height, args.fps, args.rate
    video_bytes = w * h * 2
    audio_bytes = rate // fps * 4          # 立体声 16bit
    block_sectors = (video_bytes + audio_bytes + SECTOR - 1) // SECTOR

    def audio_sectors(mod):
        # 音频落在 i % mod == mod-1 的扇区
        return (block_sectors - mod) // mod + 1 if block_sectors >= mod else 0

    audio_mod = 12
    while audio_sectors(audio_mod) * SECTOR < audio_bytes:
        audio_mod -= 1
    block_bytes = block_sectors * SECTOR
    assert block_bytes - audio_sectors(audio_mod) * SECTOR >= video_bytes
    print("block %d B (%d sec), audio every %d sec (%d sec used)" %
          (block_bytes, block_sectors, audio_mod, audio_sectors(audio_mod)))

    print("decode audio ...")
    pcm = audio_pcm(args.src, rate)
    n_audio_frames = len(pcm) // audio_bytes
    print("audio %.2fs" % (len(pcm) / 4.0 / rate))

    n_audio_sec = audio_sectors(audio_mod)
    tmp = args.dst + ".part"
    n = 0
    with open(tmp, "wb") as f:
        f.write(bytes(SECTOR))                     # 头部占位，末尾回填
        # 先按最终长度预分配再顺序写，尽量避免写一半被别的分配打断
        f.truncate(SECTOR + n_audio_frames * block_bytes)
        for buf in video_frames(args.src, w, h, fps):
            if n_audio_frames and n >= n_audio_frames:
                break
            # 本帧音频：恰好 audio_bytes 有效字节，其余扇区尾补零
            a0 = n * audio_bytes
            abuf = bytearray(n_audio_sec * SECTOR)
            chunk = pcm[a0:a0 + audio_bytes]
            abuf[0:len(chunk)] = chunk
            blk = bytearray(block_bytes)
            vp = 0
            ap_ = 0
            for s in range(block_sectors):
                o = s * SECTOR
                if s % audio_mod == audio_mod - 1:
                    blk[o:o + SECTOR] = abuf[ap_:ap_ + SECTOR]
                    ap_ += SECTOR
                else:
                    blk[o:o + SECTOR] = buf[vp:vp + SECTOR]
                    vp += SECTOR
            f.write(blk)
            n += 1
            if n % 200 == 0:
                print("  mux frame", n)

        total = SECTOR + n * block_bytes
        f.truncate(total)                          # 视频帧少于音频帧时截掉预分配尾巴
    os.replace(tmp, args.dst)
    print("muxed %s  %.1f MB  %d frames  %.2fs" %
          (args.dst, total / 1e6, n, n / fps))

    # 回读段表并回填头部（普通文件写，安全）
    drive = os.path.splitdrive(os.path.abspath(args.dst))[0]
    name = os.path.basename(args.dst)
    segs = exfat_check.sector_runs(drive, name)
    if len(segs) > MAX_RUNS:
        print("WARNING: %d segments > MAX_RUNS %d" % (len(segs), MAX_RUNS))
    hdr = bytearray(SECTOR)
    hdr[0:4] = b"EGV1"
    struct.pack_into("<HHHH", hdr, 4, 2, w, h, fps)
    struct.pack_into("<III", hdr, 12, n, block_bytes, video_bytes)
    struct.pack_into("<IHHH", hdr, 24, audio_bytes, rate, 2, block_sectors)
    struct.pack_into("<HI", hdr, 34, audio_mod, total)
    struct.pack_into("<HH", hdr, 40, len(segs), 0)
    for i, (logical, nsec, phys) in enumerate(segs[:MAX_RUNS]):
        struct.pack_into("<III", hdr, RUN_OFF + i * 12, logical, nsec, phys)
        print("  seg %d: logical %d + %d sectors -> phys %d" % (i, logical, nsec, phys))
    with open(args.dst, "r+b") as f:
        f.write(hdr)
    print("header patched (%d/%d segments)" % (min(len(segs), MAX_RUNS), len(segs)))

    write_cfg_vh(CFG_VH, w, h, fps, n, segs[0][2], block_sectors, audio_mod,
                 audio_bytes, segs)


if __name__ == "__main__":
    main()
