"""Minimal reader/writer for Larian LSPK v13 packages (Divinity: Original Sin 2 Definitive Edition).

usage:
  python lspk.py list <file.pak>
  python lspk.py extract <file.pak> <out_dir> <substring>
  python lspk.py pack <src_dir> <file.pak>
"""
import hashlib
import os
import struct
import sys
import zlib

SIGNATURE = b"LSPK"
VERSION = 13
HEADER_FMT = "<IIIHBB16s"  # Version, FileListOffset, FileListSize, NumParts, Flags, Priority, Md5
ENTRY_FMT = "<256sIIIIII"  # Name, OffsetInFile, SizeOnDisk, UncompressedSize, ArchivePart, Flags, Crc
ENTRY_SIZE = struct.calcsize(ENTRY_FMT)
PADDING = 0x40


def lz4_block_decompress(src, out_size):
    dst = bytearray()
    i = 0
    while i < len(src):
        token = src[i]; i += 1
        lit = token >> 4
        if lit == 15:
            while True:
                b = src[i]; i += 1
                lit += b
                if b != 255:
                    break
        dst += src[i:i + lit]; i += lit
        if i >= len(src):
            break
        offset = src[i] | (src[i + 1] << 8); i += 2
        mlen = token & 0x0F
        if mlen == 15:
            while True:
                b = src[i]; i += 1
                mlen += b
                if b != 255:
                    break
        mlen += 4
        start = len(dst) - offset
        for k in range(mlen):
            dst.append(dst[start + k])
    assert len(dst) == out_size, (len(dst), out_size)
    return bytes(dst)


def lz4_block_store(data):
    """Valid LZ4 block consisting of a single literal-only sequence."""
    n = len(data)
    out = bytearray()
    if n < 15:
        out.append(n << 4)
    else:
        out.append(0xF0)
        rest = n - 15
        while rest >= 255:
            out.append(255)
            rest -= 255
        out.append(rest)
    out += data
    return bytes(out)


def read_package(path):
    with open(path, "rb") as f:
        f.seek(-8, os.SEEK_END)
        header_size, sig = struct.unpack("<I4s", f.read(8))
        assert sig == SIGNATURE, sig
        f.seek(-header_size, os.SEEK_END)
        version, fl_off, fl_size, num_parts, flags, priority, md5 = struct.unpack(HEADER_FMT, f.read(struct.calcsize(HEADER_FMT)))
        header = dict(version=version, fl_off=fl_off, fl_size=fl_size, num_parts=num_parts, flags=flags, priority=priority, md5=md5.hex(), header_size=header_size)
        f.seek(fl_off)
        num_files = struct.unpack("<I", f.read(4))[0]
        raw = lz4_block_decompress(f.read(fl_size - 4), num_files * ENTRY_SIZE)
        entries = []
        for k in range(num_files):
            name, off, size, usize, part, eflags, crc = struct.unpack_from(ENTRY_FMT, raw, k * ENTRY_SIZE)
            entries.append(dict(name=name.rstrip(b"\0").decode("utf-8"), off=off, size=size, usize=usize, part=part, flags=eflags, crc=crc))
        return header, entries


def read_entry(path, e):
    with open(path, "rb") as f:
        f.seek(e["off"])
        data = f.read(e["size"])
    method = e["flags"] & 0x0F
    if method == 0:
        return data
    if method == 1:
        return zlib.decompress(data)
    if method == 2:
        return lz4_block_decompress(data, e["usize"])
    raise ValueError("unsupported compression %x" % e["flags"])


def pack(src_dir, out_path):
    files = []
    for root, _, names in os.walk(src_dir):
        for n in names:
            full = os.path.join(root, n)
            files.append((os.path.relpath(full, src_dir).replace("\\", "/"), full))
    # meta.lsx first, like LSLib-built packages.
    files.sort(key=lambda x: (not x[0].endswith("/meta.lsx"), x[0]))

    entries = []
    md5 = hashlib.md5()
    with open(out_path, "wb") as f:
        for name, full in files:
            with open(full, "rb") as fh:
                data = fh.read()
            stored = zlib.compress(data, 6)  # Flags 0x11 = zlib, default level (as used by Epip's package).
            md5.update(stored)
            off = f.tell()
            f.write(stored)
            pad = PADDING - (len(stored) % PADDING)
            if pad != PADDING:
                f.write(b"\xAD" * pad)
            entries.append(struct.pack(ENTRY_FMT, name.encode("utf-8"), off, len(stored), len(data), 0, 0x11, zlib.crc32(stored) & 0xFFFFFFFF))

        fl_off = f.tell()
        raw = b"".join(entries)
        compressed = lz4_block_store(raw)
        f.write(struct.pack("<I", len(entries)))
        f.write(compressed)
        fl_size = 4 + len(compressed)

        header = struct.pack(HEADER_FMT, VERSION, fl_off, fl_size, 1, 0, 0, md5.digest())
        f.write(header)
        f.write(struct.pack("<I4s", len(header) + 8, SIGNATURE))
    return [n for n, _ in files]


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "list":
        h, es = read_package(sys.argv[2])
        print(h)
        for e in es:
            print("%-100s off=%d size=%d usize=%d part=%d flags=%#x crc=%#x" % (e["name"], e["off"], e["size"], e["usize"], e["part"], e["flags"], e["crc"]))
    elif cmd == "extract":
        _, es = read_package(sys.argv[2])
        for e in es:
            if sys.argv[4] in e["name"]:
                dest = os.path.join(sys.argv[3], e["name"])
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                with open(dest, "wb") as fh:
                    fh.write(read_entry(sys.argv[2], e))
                print("extracted", e["name"])
    elif cmd == "pack":
        for n in pack(sys.argv[2], sys.argv[3]):
            print("packed", n)
