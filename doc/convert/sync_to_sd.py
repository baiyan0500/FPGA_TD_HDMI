import os
import sys
import glob
import shutil
import struct
import argparse

CHUNK = 4 * 1024 * 1024
SYSTEM_DIRS = {"System Volume Information", "$RECYCLE.BIN", "FOUND.000"}
SCAN_WINDOW_MB = 64


def zero_file(path):
    """删除前先把文件内容写成 0，避免物理扇区里留下可被 FPGA 识别的 BMP 头。"""
    try:
        size = os.path.getsize(path)
        if size == 0:
            return
        with open(path, "r+b") as f:
            left = size
            block = b"\0" * min(CHUNK, size)
            while left > 0:
                n = min(len(block), left)
                f.write(block[:n])
                left -= n
            f.flush()
            os.fsync(f.fileno())
    except Exception as e:
        print(f"  [警告] 无法清零 {path}: {e}")


def purge_visible_files(target_drive):
    """清零并删除卡上所有可见文件；保留系统目录。"""
    print(f"\n正在清零并删除 {target_drive} 上的旧文件...")
    removed = 0
    zeroed = 0

    for root, dirs, files in os.walk(target_drive, topdown=True):
        dirs[:] = [d for d in dirs if d not in SYSTEM_DIRS]
        for name in files:
            path = os.path.join(root, name)
            if name.lower().endswith((".bmp", ".wav")):
                zero_file(path)
                zeroed += 1
            try:
                os.remove(path)
                removed += 1
            except Exception as e:
                print(f"  [警告] 无法删除 {path}: {e}")

    for root, dirs, files in os.walk(target_drive, topdown=False):
        if os.path.normcase(root) == os.path.normcase(target_drive):
            continue
        if any(part in SYSTEM_DIRS for part in os.path.normpath(root).split(os.sep)):
            continue
        try:
            os.rmdir(root)
        except OSError:
            pass

    print(f"  已清零 {zeroed} 个 BMP/WAV，删除 {removed} 个文件。")


def fill_free_space(target_drive, max_mb=512):
    """
    用零数据覆盖空闲空间后再删除。
    默认只覆盖前 512MB：固件扫描窗口只有 64MB，没必要写满整张大卡。
    max_mb<=0 时填满全部空闲空间（小卡可用）。
    """
    free = shutil.disk_usage(target_drive).free
    reserve = 1024 * 1024
    limit = free - reserve
    if max_mb and max_mb > 0:
        limit = min(limit, max_mb * 1024 * 1024)
    target = max(0, limit)
    if target < CHUNK:
        print("\n空闲空间不足，跳过深度清理。")
        return

    filler = os.path.join(target_drive, "__zero_fill.tmp")
    print(f"\n深度清理：用零数据覆盖约 {target / 1048576:.0f} MB 空闲空间...")
    print("  覆盖范围远超 64MB 扫描窗口；可能耗时数十秒到数分钟。")

    written = 0
    last_report = 0
    try:
        with open(filler, "wb") as f:
            block = b"\0" * CHUNK
            while written < target:
                n = min(CHUNK, target - written)
                f.write(block[:n])
                written += n
                if written - last_report >= 128 * 1024 * 1024:
                    last_report = written
                    print(f"  已覆盖 {written / 1048576:.0f} MB ...")
            f.flush()
            os.fsync(f.fileno())
    except OSError as e:
        print(f"  [提示] 空间写满或写入中断，已覆盖 {written / 1048576:.0f} MB: {e}")
    finally:
        try:
            os.remove(filler)
        except OSError:
            pass

    print(f"  深度清理完成，共覆盖 {written / 1048576:.0f} MB。")


def inspect_bmp(path):
    """检查 BMP 是否满足固件扫描条件，返回 (是否合格, 说明)。"""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            head = f.read(54)
        if len(head) < 54:
            return False, "文件头不足 54 字节"
        if head[0:2] != b"BM":
            return False, "缺少 BM 魔数"

        file_size = struct.unpack_from("<I", head, 2)[0]
        offset = struct.unpack_from("<I", head, 10)[0]
        width = struct.unpack_from("<i", head, 18)[0]
        height = struct.unpack_from("<i", head, 22)[0]
        bpp = struct.unpack_from("<H", head, 28)[0]
        compression = struct.unpack_from("<I", head, 30)[0]

        if bpp != 24:
            return False, f"{bpp}bit（需要 24bit）"
        if compression != 0:
            return False, f"压缩方式 {compression}（需要 0）"
        if width <= 0 or width > 1024:
            return False, f"宽 {width}（需要 1~1024）"
        if height <= 0 or height > 2047:
            return False, f"高 {height}（需要 1~2047，且自底向上）"
        if offset >= size or file_size > size:
            return False, "文件长度或像素偏移异常"
        return True, f"{width}x{height} 24bit"
    except Exception as e:
        return False, str(e)


def sync_new_images(source_dir, target_drive, max_count=16):
    bmp_files = sorted(glob.glob(os.path.join(source_dir, "*.bmp")))
    if not bmp_files:
        print(f"\n[错误] 源文件夹 {source_dir} 中没有找到任何 BMP 图片。")
        return

    files_to_copy = bmp_files[:max_count]
    print(f"\n准备将 {len(files_to_copy)} 张图片同步到 {target_drive}...")

    success_count = 0
    total_bytes = 0
    for i, bmp_file in enumerate(files_to_copy):
        target_name = f"{i:02d}_{os.path.basename(bmp_file)}"
        target_path = os.path.join(target_drive, target_name)
        try:
            shutil.copy2(bmp_file, target_path)
            ok, info = inspect_bmp(target_path)
            total_bytes += os.path.getsize(target_path)
            if ok:
                print(f"  [同步成功] {os.path.basename(bmp_file)} -> {target_name}  ({info})")
                success_count += 1
            else:
                print(f"  [警告] {target_name} 已复制，但固件会跳过：{info}")
        except Exception as e:
            print(f"  [同步失败] {os.path.basename(bmp_file)}: {e}")

    print(f"\n同步完成，成功写入 {success_count} 张图片。")
    if total_bytes > SCAN_WINDOW_MB * 1024 * 1024:
        print(f"[警告] 图片总大小 {total_bytes / 1048576:.1f} MB 超过固件 {SCAN_WINDOW_MB} MB 扫描窗口，后面的图片可能找不到。")
    print("请安全弹出 TF 卡，并给开发板断电重新上电；固件只在初始化时扫描一次。")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="FPGA SD卡 图片同步工具（清除物理扇区残留）")
    parser.add_argument('drive', help='SD 卡所在的盘符 (例如: E: 或 E:\\)')
    parser.add_argument('-s', '--source', help='存放转换好 BMP 图片的源文件夹 (默认: 当前目录的 output_bmp)', default=None)
    parser.add_argument('-n', '--num', type=int, default=16, help='最多同步的图片数量 (默认: 16)')
    parser.add_argument('--deep', action='store_true',
                        help='用零数据覆盖空闲空间，清除以前手动删除留下的扇区残留（默认覆盖前 512MB）')
    parser.add_argument('--deep-mb', type=int, default=512,
                        help='--deep 覆盖的空闲空间大小，单位 MB；0 表示填满全部空闲空间（默认: 512）')

    args = parser.parse_args()

    target_drive = args.drive
    if not target_drive.endswith(':\\') and not target_drive.endswith(':/'):
        if target_drive.endswith(':'):
            target_drive += '\\'
        else:
            target_drive += ':\\'

    if not os.path.exists(target_drive):
        print(f"[致命错误] 找不到指定的驱动器: {target_drive}")
        print("请检查 SD 卡是否已正确插入电脑并分配了盘符。")
        sys.exit(1)

    current_dir = os.path.dirname(os.path.abspath(__file__))
    source_dir = args.source if args.source else os.path.join(current_dir, "output_bmp")

    print("=" * 50)
    print(f"目标 SD 卡盘符: {target_drive}")
    print(f"图片源文件夹  : {source_dir}")
    print("=" * 50)

    if target_drive.upper().startswith('C:'):
        confirm = input("警告: 你指定了系统盘(C:)！这可能会导致系统崩溃。你确定要继续吗？(y/N): ")
        if confirm.lower() != 'y':
            print("操作已取消。")
            sys.exit(0)

    source_drive, _ = os.path.splitdrive(os.path.abspath(source_dir))
    target_letter, _ = os.path.splitdrive(os.path.abspath(target_drive))
    if source_drive.upper() == target_letter.upper():
        print("[错误] 源文件夹不能位于目标 TF 卡上，否则清卡会删除源图片。")
        sys.exit(1)

    purge_visible_files(target_drive)
    if args.deep:
        fill_free_space(target_drive, args.deep_mb)
    sync_new_images(source_dir, target_drive, max_count=args.num)
