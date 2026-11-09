# gpu/a04s/metal/chlorophyll: what is copied from Chlorophyll

- **Source:** [github.com/ry-diffusion/Chlorophyll](https://github.com/ry-diffusion/Chlorophyll) at `787338f` (Bergamota's Metal driver for the Poco F1's Adreno 630 on iOS 18).
- **Licence:** MIT, `Copyright (c) 2026 OOSEX GANG`. The text is `LICENSE` here, copied from Chlorophyll's `LICENSE.hackios-userland`. Chlorophyll's own `NOTICE.md` puts its device code (`src/bgmtl.m`, SPDX MIT) under the same licence.
- **Permission:** the owner OK'd using Chlorophyll and Bergamota for the A04s's Metal track on 2026-11-07.

| File here | From | A04s changes |
|---|---|---|
| `bgmtl.m` | `src/bgmtl.m` | Marked "A04s" in the source: a header note; the fence retry no longer asks Bergamota's `sweet_drm` for its wait record; `bgmtl_gpu_state` checks for the HeroGPU service instead of Bergamota's GPU-info call. M6: a draw through a stand-in for a refused pipeline is skipped and logged. The unbound-texture line is logged 32 times at most. Metal's viewport rectangle is kept, and a pass into another mip level or slice is logged. An IOSurface the GPU cannot import gets a copy refreshed from it when sampled. M6 run 7: the trace also shows fragment buffer binds, what each holds at a draw, and every sampler's settings. Line endings made LF. |

- **M5** built `bgmtl.m` against the S9+ port's copy of the AIR front end and library (`../hakios/mesa/air`), which carries the Panfrost changes M1 checked. Chlorophyll's few library calls that copy lacked were added there.
- **Since M6** the A04s builds from `../air`: Chlorophyll's `air/` at the same commit, with the S9+ copy's Panfrost changes and the A04s's own ported onto it (`../air/NOTICE.md`).
- **Not copied:** Chlorophyll's freedreno patches, Bergamota's kernel interface, the injection and the system plug-in.
- **Copied with changes:** the M6a probe's CoreAnimation scenes (`../m5/a04s_ca_scenes.m`) come from Chlorophyll's `test/bgmtl_carenderer_probe.m`.
