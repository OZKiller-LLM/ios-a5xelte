#!/usr/bin/env python3
# Copyright (c) 2026 Scion-Project contributors
# SPDX-License-Identifier: MIT
"""The pictures of tools/mali-drmshim-check.sh: glReadPixels output (RGBA, bottom row first).

    image.py png IN.rgba WIDTH HEIGHT OUT.png      the picture, top row first, as a PNG
    image.py compare A.rgba B.rgba WIDTH HEIGHT    how far two pictures are apart

A phone run of the Mali and softpipe's are not expected to agree byte for byte: the
fragment shader is `precision mediump`, which the Mali runs in 16-bit floats and softpipe in
32, so a varying's colour may differ by a step or two. compare says how many bytes differ
and by how much at most, which is the number to judge a phone's framebuffer by.
"""
import struct
import sys
import zlib


def png(path, w, h, out):
    raw = open(path, 'rb').read()
    assert len(raw) == w * h * 4, 'not %d x %d RGBA' % (w, h)
    rows = []
    for y in range(h):
        row = raw[(h - 1 - y) * w * 4:(h - y) * w * 4]
        sub = bytes((row[i] - (row[i - 4] if i >= 4 else 0)) & 255 for i in range(len(row)))
        rows.append(b'\x01' + sub)

    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(out, 'wb').write(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) +
                          chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))


def compare(a, b, w, h):
    x, y = open(a, 'rb').read(), open(b, 'rb').read()
    if len(x) != w * h * 4 or len(y) != w * h * 4:
        print('image.py: not both %d x %d RGBA' % (w, h))
        return 1
    diff = [abs(p - q) for p, q in zip(x, y) if p != q]
    print('image.py: %d of %d bytes differ, by at most %d' % (len(diff), len(x), max(diff) if diff else 0))
    return 0 if not diff else 1


if __name__ == '__main__':
    if sys.argv[1] == 'png':
        png(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5])
    else:
        sys.exit(compare(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5])))
