#!/usr/bin/env python3
"""Build the stage 6a ADT for the Galaxy A04s (SM-A047F, Exynos 850).

CPUs, memory, the GIC, the screen S-Boot leaves running, the eMMC host's registers and
the iOS display service for that screen (CPU copies only, no display registers). It has
no GPU, touch or sensor nodes, so nothing can bind to them. Values come from this phone's
live device tree and the boot probe.
"""
import argparse
import os
from pathlib import Path

import adt
import mkadt

SOC_BASE = 0x10000000
# 672 MiB, the most of the first free RAM window at 32 MiB alignment. It ends below secure firmware.
DRAM_BASE, DRAM_SIZE = 0x92000000, 0x2A000000
GICD, GICD_SIZE = 0x12a01000, 0x1000
GICC, GICC_SIZE = 0x12a02000, 0x2000
FB, FB_W, FB_H = 0xfa000000, 720, 1600
# The screen iOS is given: the iPhone XR's, 414x896 points at @2x. The kernel scales it to the
# panel, x0.870 across and x0.893 down (nearest), so it is 2.7% taller than it should be.
CANVAS_W, CANVAS_H = 828, 1792
EMMC, EMMC_SIZE = 0x12100000, 0x2000
TIMEBASE = 26000000
CPU_HZ = 2000000000


def set_prop(node, name, value):
    for i, (key, flags, _) in enumerate(node.props):
        if key == name:
            node.props[i] = (key, flags, value)
            return
    node.props.append((name, 0, value))


def child(node, name):
    for candidate in node.children:
        if candidate.prop('name') == mkadt.cstr(name):
            return candidate
    raise ValueError(f'missing donor ADT node {name}')


def cpu_compatible():
    # SweetCPU matches 'arm,cortex-a53' in this port's shared IOKit table.
    return mkadt.cstr('arm,cortex-a55') + mkadt.cstr('arm,cortex-a53') + mkadt.cstr('ARM,v8')


def build(seed=None):
    root = mkadt.build(seed=seed if seed is not None else os.urandom(64), qemu=True)
    # 'samsung,a5xelte' is what the shared platform expert matches.
    set_prop(root, 'compatible', mkadt.cstr('samsung,a04s') + mkadt.cstr('samsung,a5xelte') +
             mkadt.cstr('samsung,exynos850') + mkadt.cstr('AppleARM'))
    chosen = child(root, 'chosen')
    set_prop(chosen, 'dram-base', mkadt.u64(DRAM_BASE))
    set_prop(chosen, 'dram-size', mkadt.u64(DRAM_SIZE))
    set_prop(chosen, 'firmware-version', mkadt.cstr('a04s-stage6a-4'))
    set_prop(chosen, 'system-firmware-version', mkadt.cstr('a04s-stage6a-4'))
    # UIKit picks its status bar by pixel width and notch, and draws a red placeholder for the
    # panel's 720 pixels (and for 750). The canvas and artwork are the iPhone XR's, the @2x
    # notched iPhone, as mkadt_herolte.py --scale2.
    set_prop(chosen, 'display-scale', mkadt.u32(2))
    product = child(root, 'product')
    set_prop(product, 'artwork-device-subtype', mkadt.u32(1792))
    set_prop(product, 'artwork-scale-factor', mkadt.u32(2))
    # MobileGestalt derives the UDID from these; without them SpringBoard stays on the boot logo.
    # Synthetic, locally administered addresses, not the phone's.
    for name, last in (('wifi0', 1), ('bluetooth0', 2), ('ethernet0', 3)):
        set_prop(chosen, f'mac-address-{name}', bytes((0x02, 0x41, 0x30, 0x34, 0x53, last)))

    # Two clusters of four: MPIDR 0..3 and 0x100..0x103. cpus=1 selects only the first.
    cpus = child(root, 'cpus')
    cpu0 = child(cpus, 'cpu0')
    set_prop(cpu0, 'compatible', cpu_compatible())
    set_prop(cpu0, 'reg', mkadt.u32(0))
    set_prop(cpu0, 'timebase-frequency', mkadt.u32(TIMEBASE))
    set_prop(cpu0, 'clock-frequency', mkadt.u32(CPU_HZ))
    set_prop(cpu0, 'peripheral-frequency', mkadt.u32(TIMEBASE))
    set_prop(cpu0, 'fixed-frequency', mkadt.u32(TIMEBASE))
    for logical in range(1, 8):
        cluster, core = divmod(logical, 4)
        cpus.children.append(mkadt.node(f'cpu{logical}', [
            ('device_type', mkadt.cstr('cpu')),
            ('compatible', cpu_compatible()),
            ('reg', mkadt.u32((cluster << 8) | core)),
            ('cpu-id', mkadt.u32(logical)),
            ('cluster-id', mkadt.u32(cluster)),
            ('cluster-type', mkadt.u32(0)),
            ('die-cluster-id', mkadt.u32(cluster)),
            ('cluster-core-id', mkadt.u32(core)),
            ('l2-cache-id', mkadt.u32(cluster)),
            ('l3-cache-id', mkadt.u32(0)),
            ('state', mkadt.cstr('stopped')),
            ('timebase-frequency', mkadt.u32(TIMEBASE)),
            ('clock-frequency', mkadt.u32(CPU_HZ)),
            ('bus-frequency', mkadt.u32(100000000)),
            ('memory-frequency', mkadt.u32(1866000000)),
            ('peripheral-frequency', mkadt.u32(TIMEBASE)),
            ('fixed-frequency', mkadt.u32(TIMEBASE)),
        ]))

    arm_io = child(root, 'arm-io')
    set_prop(arm_io, 'device_type', mkadt.cstr('a04s-io'))
    set_prop(arm_io, 'compatible', mkadt.cstr('samsung,exynos850-io') + mkadt.cstr('arm-io'))
    set_prop(arm_io, 'ranges', mkadt.u64(0, SOC_BASE, 0x100000000 - SOC_BASE))
    # The wdt node has no hardware behind it: it only tells watchdogd there is no PMU.
    arm_io.children = [n for n in arm_io.children if n.prop('name') == mkadt.cstr('wdt')]
    arm_io.children.append(mkadt.node('gic', [
        ('compatible', mkadt.cstr('arm,cortex-a15-gic')),
        ('interrupt-controller', mkadt.cstr('master')),
        ('virtual-timer-intid', mkadt.u32(27)),
        ('reg', mkadt.u64(GICD - SOC_BASE, GICD_SIZE, GICC - SOC_BASE, GICC_SIZE)),
    ]))
    # AppleCLCD (SweetFramebuffer.cpp) matches the compatible string. backboardd sizes its
    # surfaces from the canvas, and the A04S kernel presents the canvas it finds here.
    arm_io.children.append(mkadt.node('disp0', [
        ('device_type', mkadt.cstr('display-subsystem')),
        ('compatible', mkadt.cstr('samsung,a5xelte-display')),
        ('canvas-width', mkadt.u32(CANVAS_W)),
        ('canvas-height', mkadt.u32(CANVAS_H)),
    ]))

    root.children = [n for n in root.children if n.prop('name') not in
                     (mkadt.cstr('sweet-fbcon'), mkadt.cstr('sweet-ufs'))]
    # The shared console looks this node up by name.
    root.children.append(mkadt.node('a5xelte-fbcon', [
        ('reg', mkadt.u64(FB, FB_W * FB_H * 4)),
        ('width', mkadt.u32(FB_W)),
        ('height', mkadt.u32(FB_H)),
        ('stride', mkadt.u32(FB_W * 4)),
    ]))
    # The shared eMMC driver looks this node up by name, and checks the address.
    root.children.append(mkadt.node('a5xelte-emmc', [
        ('reg', mkadt.u64(EMMC, EMMC_SIZE)),
    ]))
    return root


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    blob = adt.serialize(build())
    args.output.write_bytes(blob)
    print(f'{args.output}: {len(blob)} bytes')
