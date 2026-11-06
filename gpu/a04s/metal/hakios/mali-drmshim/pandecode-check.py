#!/usr/bin/env python3
# Copyright (c) 2026 Scion-Project contributors
# SPDX-License-Identifier: MIT
"""Read what Mesa's panfrost decoded of its own job chains (PAN_MESA_DEBUG=trace, one
pandecode.dump.* file per submit) under tools/mali-drmshim's shim, and judge it.

    pandecode-check.py DUMP_DIR SHIM_TRACE [STDERR_LOG]

Counted: the dumps, the jobs by type, the descriptors decoded. Failed on:
  - any line of the decoder's own complaints ("XXX", "Access to unknown memory", "Incomplete
    job") other than the two it prints for every Bifrost job panfrost makes, each recognised
    only in its exact form:
      * "ZS/S Write Format: XXX: INVALID" in a ZS CRC extension whose ZS and S writeback bases
        are 0 (no depth or stencil buffer: the format is left 0, an enum value with no name)
      * "XXX: null pointer deref" immediately followed by "ubuf_N[0] = 0x0" (an empty uniform
        buffer slot: every uniform was pushed)
      * a "Varying:" record of Type XXX: INVALID whose pointer, stride and size are all 0: the
        general-varying buffer panfrost zeroes when a shader pair passes nothing but the
        position (pan_cmdstream.c, panfrost_emit_varying_descriptor)
    and the overlays the decoder prints whatever the descriptor holds: a blend descriptor in
    Mode: Shader has no equation or fixed-function conversion (their INVALIDs are not errors),
    and a render target's YUV overlay (Plane N Base) means nothing unless YUV Enable is true, nor
    its AFBC overlay unless the Writeback Block Format is AFBC, nor its RGB Base when it is
  - a GPU address in a pointer field outside 32 MB .. 4 GB, or outside every buffer the shim
    gave out (SHIM_TRACE: HAKIOS_MALI_SHIM_TRACE's log)
  - a shader's code address (a renderer state's Shader, a blend descriptor's PC in Shader mode)
    not in an executable buffer, or that buffer crossing a 16 MB line
Exit status 0 when nothing failed.
"""
import collections
import glob
import os
import re
import sys

FIRST, END, LINE = 0x02000000, 0x100000000, 0x1000000
POINTER = re.compile(r'^( *)([A-Za-z0-9 ]*(?:Pointer|Base|Heap|Polygon List|Varyings|Attributes|Next|'
                     r'Frame Shader DCDs|Shader|Address|Constants|Descriptors|Indices|Position|'
                     r'Textures|Samplers|Uniform Buffers|Push Uniforms|Thread Storage|Renderer State)): '
                     r'(0x[0-9a-f]+)$')


def block_end(lines, i):
    """The line after the block that starts at lines[i] (its lines are indented deeper)."""
    indent = len(lines[i]) - len(lines[i].lstrip())
    j = i + 1
    while j < len(lines) and (lines[j].strip() == '' or len(lines[j]) - len(lines[j].lstrip()) > indent):
        if lines[j].strip() == '' and j + 1 < len(lines) and \
                len(lines[j + 1]) - len(lines[j + 1].lstrip()) <= indent:
            break
        j += 1
    return j


def blank(lines, a, b, what, explained):
    """The overlay lines a..b-1 that do not apply: dropped, their complaints counted as explained."""
    for k in range(a, b):
        if 'XXX' in lines[k]:
            explained[what] += 1
        lines[k] = ''


def overlays(lines, explained):
    lines = list(lines)
    for i, line in enumerate(lines):
        s = line.strip()
        if re.match(r'Color Render Target \d+:$', s):
            end = block_end(lines, i)
            body = lines[i:end]
            yuv = any(l.strip() == 'YUV Enable: true' for l in body)
            afbc = any(l.strip() == 'Writeback Block Format: AFBC' for l in body)
            for k in range(i + 1, end):
                t = lines[k].strip()
                if (t == 'YUV:' and not yuv) or (t == 'AFBC:' and not afbc) or (t == 'RGB:' and afbc):
                    blank(lines, k, block_end(lines, k), 'render target overlay not in use', explained)
        if re.match(r'Blend RT \d+:$', s):
            end = block_end(lines, i)
            if any(l.strip() == 'Mode: Shader' for l in lines[i:end]):
                for k in range(i + 1, end):
                    t = lines[k].strip()
                    if t in ('Equation:', 'Fixed-Function:') and lines[k] != '':
                        blank(lines, k, block_end(lines, k),
                              'blend equation/fixed-function fields with a blend shader (Mode: Shader)', explained)
    return lines


def main():
    dump_dir, trace = sys.argv[1], sys.argv[2]
    stderr_log = sys.argv[3] if len(sys.argv) > 3 else None
    bos = []
    for line in open(trace):
        m = re.match(r'bo va (0x[0-9a-f]+) size (0x[0-9a-f]+) flags (\S+)( exec)?', line)
        if m:
            bos.append((int(m.group(1), 16), int(m.group(2), 16), bool(m.group(4))))

    def bo_of(addr):
        for va, size, ex in bos:
            if va <= addr < va + size:
                return va, size, ex
        return None

    files = sorted(glob.glob(os.path.join(dump_dir, 'pandecode.dump.*')))
    jobs = collections.Counter()
    sections = 0
    explained = collections.Counter()
    failures = []
    pointers = 0
    code = set()
    blend_shaders = 0
    for path in files:
        lines = overlays(open(path, errors='replace').read().split('\n'), explained)
        name = os.path.basename(path)
        mode = None
        zs_bases = {}
        for i, line in enumerate(lines):
            s = line.strip()
            if s.startswith('Type: ') and i > 0 and any('Job Header' in l for l in lines[max(0, i - 12):i]):
                jobs[s[6:]] += 1
            if re.match(r'^[A-Z][A-Za-z0-9 ()]*:$', line):
                sections += 1
            if s.startswith('Mode: '):
                mode = s[6:]
            m = re.match(r'(ZS|S) Writeback Base: (0x[0-9a-f]+)', s)
            if m:
                zs_bases[m.group(1)] = int(m.group(2), 16)
            if 'XXX' in s or 'unknown memory' in s or 'Incomplete job' in s:
                if re.match(r'(ZS|S) Write Format: XXX: INVALID$', s):
                    # the bases come before (CRC extension: bases then formats) or after; look around
                    window = '\n'.join(lines[max(0, i - 20):i + 20])
                    bases = [int(x, 16) for x in re.findall(r'(?:ZS|S) Writeback Base: (0x[0-9a-f]+)', window)]
                    if bases and all(b == 0 for b in bases):
                        explained['ZS/S write format left 0 with no depth/stencil buffer'] += 1
                        continue
                if s == 'Type: XXX: INVALID' and i > 0 and lines[i - 1].strip() == 'Varying:' and \
                        [l.strip() for l in lines[i + 1:i + 4]] == ['Pointer: 0x0', 'Stride: 0', 'Size: 0']:
                    explained['general varying buffer left zero (no varyings but the position)'] += 1
                    continue
                if s == '// XXX: null pointer deref' and i + 1 < len(lines) and \
                        re.match(r'ubuf_\d+\[0\] = 0x0;$', lines[i + 1].strip()):
                    explained['empty uniform buffer slot (uniforms pushed)'] += 1
                    continue
                failures.append('%s:%d: %s' % (name, i + 1, s))
                continue
            m = POINTER.match(line)
            if m and m.group(2).strip() not in ('Shader',) or (m and m.group(2).strip() == 'Shader'):
                addr = int(m.group(3), 16)
                field = m.group(2).strip()
                if addr == 0:
                    continue
                pointers += 1
                if not FIRST <= addr < END:
                    failures.append('%s:%d: %s %#x outside 32 MB..4 GB' % (name, i + 1, field, addr))
                    continue
                bo = bo_of(addr)
                if bo is None:
                    failures.append('%s:%d: %s %#x in no buffer the shim gave' % (name, i + 1, field, addr))
                    continue
                if field == 'Shader' and line.startswith('    Shader:'):
                    code.add((addr, bo))
            m = re.match(r' *PC: (\d+)$', line)
            if m and mode == 'Shader':
                addr = int(m.group(1))
                blend_shaders += 1
                bo = bo_of(addr)
                if bo is None:
                    failures.append('%s:%d: blend shader PC %#x in no buffer' % (name, i + 1, addr))
                else:
                    code.add((addr, bo))
    for addr, (va, size, ex) in sorted(code):
        if not ex:
            failures.append('code at %#x is in a buffer without execute (%#x, %#x bytes)' % (addr, va, size))
        if va // LINE != (va + size - 1) // LINE:
            failures.append('code at %#x is in a buffer across a 16 MB line (%#x, %#x bytes)' % (addr, va, size))
    if stderr_log:
        for line in open(stderr_log, errors='replace'):
            if 'unknown memory' in line or 'XXX' in line or 'Incomplete job' in line:
                failures.append('stderr: ' + line.strip())

    print('pandecode-check: %d dumps, %d jobs (%s), %d descriptor sections decoded, %d pointers checked '
          '(%d buffers, %d of them executable), %d code addresses (%d of them blend shader PCs), all in '
          'executable buffers inside one 16 MB line: %s' % (
              len(files), sum(jobs.values()), ', '.join('%s %d' % kv for kv in sorted(jobs.items())), sections,
              pointers, len(bos), sum(1 for b in bos if b[2]), len(code), blend_shaders,
              'yes' if not any('code at' in f for f in failures) else 'NO'))
    for what, n in sorted(explained.items()):
        print('pandecode-check: explained, not an error: %d x %s' % (n, what))
    for f in failures[:40]:
        print('pandecode-check: FAIL ' + f)
    print('pandecode-check: %s (%d failures)' % ('PASS' if not failures and files else 'FAIL', len(failures)))
    return 0 if not failures and files else 1


if __name__ == '__main__':
    sys.exit(main())
