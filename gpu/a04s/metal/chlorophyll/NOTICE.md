# gpu/a04s/metal/chlorophyll: what is copied from Chlorophyll

- **Source:** [github.com/ry-diffusion/Chlorophyll](https://github.com/ry-diffusion/Chlorophyll) at `787338f` (Bergamota's Metal driver for the Poco F1's Adreno 630 on iOS 18).
- **Licence:** MIT, `Copyright (c) 2026 OOSEX GANG`. The text is `LICENSE` here, copied from Chlorophyll's `LICENSE.hackios-userland`. Chlorophyll's own `NOTICE.md` puts its device code (`src/bgmtl.m`, SPDX MIT) under the same licence.
- **Permission:** the owner OK'd using Chlorophyll and Bergamota for the A04s's Metal track on 2026-11-07.

| File here | From | A04s changes |
|---|---|---|
| `bgmtl.m` | `src/bgmtl.m` | Marked "A04s" in the source: a header note; the fence retry no longer asks Bergamota's `sweet_drm` for its wait record; `bgmtl_gpu_state` checks for the HeroGPU service instead of Bergamota's GPU-info call. Line endings made LF. |

Not copied: Chlorophyll's AIR front end and `libbgair` (`air/`). The A04s builds `bgmtl.m` against the S9+ port's copy in `../hakios/mesa/air`, which carries the Panfrost changes M1 checked. Chlorophyll's few library calls that copy lacks were added there, marked "A04s (Metal track M5)". Also not copied: its freedreno patches, the Bergamota kernel interface, the injection and the system plug-in.
