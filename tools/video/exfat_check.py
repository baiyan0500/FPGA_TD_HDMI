#!/usr/bin/env python3
"""exFAT 只读解析：查文件的物理簇段（run）布局

FPGA 侧按裸扇区顺序读文件，必须知道文件在卷上的物理段表；
容器头里保存这份段表（见 mp4_to_egv.py），因此需要从 FAT 链反推。

用法: python exfat_check.py F: VIDEO.EGV
"""
import ctypes
import struct
import sys
from ctypes import wintypes

GENERIC_READ = 0x80000000
FILE_SHARE_ALL = 0x7
OPEN_EXISTING = 3
MEM_COMMIT = 0x1000
MEM_RESERVE = 0x2000
PAGE_READWRITE = 0x04
INVALID_HANDLE = ctypes.c_void_p(-1).value


class Reader:
    def __init__(self, drive):
        self.k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32 = self.k32
        k32.CreateFileW.restype = wintypes.HANDLE
        k32.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                    wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                                    wintypes.HANDLE]
        k32.VirtualAlloc.restype = wintypes.LPVOID
        k32.VirtualAlloc.argtypes = [wintypes.LPVOID, ctypes.c_size_t,
                                     wintypes.DWORD, wintypes.DWORD]
        k32.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                                 ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
        k32.SetFilePointerEx.argtypes = [wintypes.HANDLE, ctypes.c_int64,
                                         ctypes.POINTER(ctypes.c_int64), wintypes.DWORD]
        self.h = k32.CreateFileW("\\\\.\\%s" % drive.rstrip("\\/"),
                                 GENERIC_READ, FILE_SHARE_ALL, None,
                                 OPEN_EXISTING, 0, None)
        if not self.h or self.h == INVALID_HANDLE:
            raise OSError(ctypes.get_last_error(),
                          "CreateFileW failed (need admin / elevated shell?)")
        self.buf_sz = 1 << 20
        self.buf = k32.VirtualAlloc(None, self.buf_sz, MEM_COMMIT | MEM_RESERVE,
                                    PAGE_READWRITE)

    def read(self, offset, size):
        assert size % 512 == 0
        out = b""
        while size > 0:
            n = min(size, self.buf_sz)
            newpos = ctypes.c_int64(0)
            self.k32.SetFilePointerEx(self.h, offset, ctypes.byref(newpos), 0)
            got = wintypes.DWORD(0)
            if not self.k32.ReadFile(self.h, self.buf, n, ctypes.byref(got), None):
                raise OSError(ctypes.get_last_error(), "ReadFile failed")
            out += ctypes.string_at(self.buf, got.value)
            offset += got.value
            size -= got.value
        return out

    def close(self):
        self.k32.CloseHandle(self.h)


def file_info(drive, name):
    """返回 dict: name, first_cluster, length, nofat, runs=[(clu_start, nclu)], csz"""
    r = Reader(drive)
    try:
        bs = r.read(0, 512)
        if bs[3:11] != b"EXFAT   ":
            raise ValueError("not an exFAT volume: %r" % bs[3:11])
        bps = 1 << bs[108]
        spc = 1 << bs[109]
        csz = bps * spc
        fat_off = struct.unpack_from("<I", bs, 80)[0]
        fat_len = struct.unpack_from("<I", bs, 84)[0]
        heap_off = struct.unpack_from("<I", bs, 88)[0]
        root_clu = struct.unpack_from("<I", bs, 96)[0]
        fat = r.read(fat_off * bps, fat_len * bps)

        def chain(start):
            out, clu = [], start
            while 2 <= clu < 0xFFFFFFF7:
                out.append(clu)
                clu = struct.unpack_from("<I", fat, clu * 4)[0]
            return out

        root = b""
        for c in chain(root_clu):
            root += r.read((heap_off + (c - 2) * spc) * bps, csz)

        want = name.upper()
        found = None
        for i in range(0, len(root), 32):
            e = root[i:i + 32]
            if e[0] != 0x85 or i + 64 > len(root) or root[i + 32] != 0xC0:
                continue
            nlen = e[3]
            s = root[i + 32:i + 64]
            raw, j = b"", i + 64
            while len(raw) < nlen * 2 and j + 32 <= len(root) and root[j] == 0xC1:
                raw += root[j + 2:j + 32]
                j += 32
            nm = raw[:nlen * 2].decode("utf-16-le", "replace").rstrip("\x00")
            if nm.upper() == want:
                found = dict(name=nm,
                             first_cluster=struct.unpack_from("<I", s, 20)[0],
                             length=struct.unpack_from("<Q", s, 24)[0],
                             nofat=bool(s[1] & 0x02))
                break
        if not found:
            raise FileNotFoundError(name)

        ch = chain(found["first_cluster"]) if not found["nofat"] else None
        if ch is None:
            nclu = -(-found["length"] // csz)
            ch = list(range(found["first_cluster"], found["first_cluster"] + nclu))
        runs, start, prev = [], ch[0], ch[0]
        for c in ch[1:]:
            if c != prev + 1:
                runs.append((start, prev - start + 1))
                start = c
            prev = c
        runs.append((start, prev - start + 1))
        found["runs"] = runs
        found["heap_lba"] = heap_off
        found["spc"] = spc
        found["csz"] = csz
        found["clusters"] = len(ch)
        return found
    finally:
        r.close()


def sector_runs(drive, name):
    """段表按 512B 扇区给出: [(logical_lba, n_sectors, phys_lba)]"""
    fi = file_info(drive, name)
    total_sectors = -(-fi["length"] // 512)
    out, logical = [], 0
    for start, nclu in fi["runs"]:
        n_sec = nclu * fi["spc"]
        n_sec = min(n_sec, total_sectors - logical)
        out.append((logical, n_sec, fi["heap_lba"] + (start - 2) * fi["spc"]))
        logical += n_sec
    return out


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    drive, name = sys.argv[1], sys.argv[2]
    fi = file_info(drive, name)
    print("file %r  first cluster %d  size %d  NoFatChain %s  cluster %d B"
          % (fi["name"], fi["first_cluster"], fi["length"], fi["nofat"], fi["csz"]))
    sr = sector_runs(drive, name)
    print("segments %d" % len(sr))
    for i, (logical, n, phys) in enumerate(sr):
        print("  seg %2d: logical lba %8d + %7d sectors  -> physical lba %8d  (%.2f MB)"
              % (i, logical, n, phys, n * 512 / 1e6))
    return 0 if len(sr) == 1 else 3


if __name__ == "__main__":
    sys.exit(main())
