"""Lists named PlaceObject instances in a SWF with their translation, recursing into sprites."""
import struct
import sys


class Bits:
    def __init__(self, data, pos):
        self.data, self.byte, self.bit = data, pos, 0

    def read(self, n):
        v = 0
        for _ in range(n):
            b = (self.data[self.byte] >> (7 - self.bit)) & 1
            v = (v << 1) | b
            self.bit += 1
            if self.bit == 8:
                self.bit, self.byte = 0, self.byte + 1
        return v

    def sread(self, n):
        v = self.read(n)
        if n and v & (1 << (n - 1)):
            v -= 1 << n
        return v

    def align(self):
        if self.bit:
            self.bit, self.byte = 0, self.byte + 1


def read_matrix(data, pos):
    b = Bits(data, pos)
    if b.read(1):
        n = b.read(5); b.read(n); b.read(n)
    if b.read(1):
        n = b.read(5); b.read(n); b.read(n)
    n = b.read(5)
    tx, ty = b.sread(n), b.sread(n)
    b.align()
    return tx / 20.0, ty / 20.0, b.byte


def read_cxform_alpha(data, pos):
    b = Bits(data, pos)
    has_add, has_mult = b.read(1), b.read(1)
    n = b.read(4)
    if has_mult:
        for _ in range(4): b.read(n)
    if has_add:
        for _ in range(4): b.read(n)
    b.align()
    return b.byte


def cstr(data, pos):
    end = data.index(b"\0", pos)
    return data[pos:end].decode("latin-1"), end + 1


sprites = {}


def walk(data, pos, end, owner, out):
    while pos < end:
        code_len = struct.unpack_from("<H", data, pos)[0]; pos += 2
        code, length = code_len >> 6, code_len & 0x3F
        if length == 0x3F:
            length = struct.unpack_from("<I", data, pos)[0]; pos += 4
        body = pos
        pos += length
        if code == 0:
            break
        if code == 39:  # DefineSprite
            sid = struct.unpack_from("<H", data, body)[0]
            sprites[sid] = (body + 4, pos)
        elif code in (26, 70):
            p = body
            flags = data[p]; p += 1
            flags2 = 0
            if code == 70:
                flags2 = data[p]; p += 1
            depth = struct.unpack_from("<H", data, p)[0]; p += 2
            if code == 70 and (flags2 & 0x08 or (flags2 & 0x10 and flags & 0x02)):
                _, p = cstr(data, p)  # class name
            cid = None
            if flags & 0x02:
                cid = struct.unpack_from("<H", data, p)[0]; p += 2
            tx = ty = None
            if flags & 0x04:
                tx, ty, p = read_matrix(data, p)
            if flags & 0x08:
                p = read_cxform_alpha(data, p)
            if flags & 0x10:
                p += 2
            name = None
            if flags & 0x20:
                name, p = cstr(data, p)
            out.append((owner, depth, cid, name, tx, ty))


def main():
    data = open(sys.argv[1], "rb").read()
    nbits = data[8] >> 3
    pos = 8 + (5 + nbits * 4 + 7) // 8 + 4
    out = []
    walk(data, pos, len(data), "root", out)
    for sid, (s, e) in list(sprites.items()):
        walk(data, s, e, "sprite%d" % sid, out)
    for row in out:
        if row[3]:
            print("%-10s depth=%-4s char=%-5s %-28s x=%s y=%s" % row)


main()
