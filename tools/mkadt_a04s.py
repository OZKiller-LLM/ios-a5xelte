#!/usr/bin/env python3
"""Build the stage 5c ADT for the Galaxy A04s (SM-A047F, Exynos 850).

CPUs, memory, the GIC, the screen S-Boot leaves running and the eMMC host's registers,
which the kernel uses read-only. It has no display service, GPU, touch or sensor nodes,
so nothing can bind to them. Values come from this phone's live device tree and the
boot probe.
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
    set_prop(chosen, 'firmware-version', mkadt.cstr('a04s-stage5c'))
    set_prop(chosen, 'system-firmware-version', mkadt.cstr('a04s-stage5c'))

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
