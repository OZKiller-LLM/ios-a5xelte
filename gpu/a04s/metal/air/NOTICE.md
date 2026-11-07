# gpu/a04s/metal/air: the AIR front end and libhakiosair the A04s builds (since M6)

The Metal shader front end (AIR → NIR, `air_*.c`, `nir_air.h`, `air2nir.c`, `meson.build`) and the Metal driver's library (`air_metal.c`, `air_metal.h`). From M6 on, both `check.sh` and `m5/build-mesa-ios.sh` build from here.

## Where it comes from

- **The base:** Chlorophyll's `air/` at `787338f` ([github.com/ry-diffusion/Chlorophyll](https://github.com/ry-diffusion/Chlorophyll)).
  - MIT, `Copyright (c) 2026 OOSEX GANG`; the licence is `../chlorophyll/LICENSE`.
  - Chlorophyll took it from the hackios userland (`hackios-xnu-userland` @ `29eef72`, `tools/mesa/`, MIT, "Darwin on redwood contributors") and added Bergamota's changes. Those include the function-constant folder and `air.static_init` evaluator that iOS's QuartzCore needs.
- **The S9+ copy's Panfrost changes**, ported from `../hakios/mesa/air` (the Galaxy S9+ port at `2d09239`, MIT; reuse OK'd by its author):
  - Panfrost's constant-buffer base (`ubo_base`, `shift_ubo_index`);
  - Bifrost's graphics I/O in `finalize_for_gallium`;
  - the driver table that opens Panfrost;
  - unsigned render-target outputs.
- **The A04s's own changes**, marked "A04s" in the source:
  - **M1c:** an image store typed by its value; the `[[threadgroup(0)]]` buffer length (`rwa_compute_set_threadgroup_memory_length`); `air_metal_test.c` from the S9+ copy.
  - **M6:**
    - IOSurface import and cache flush through `gpu/mesa/herodrm.c` instead of Bergamota's `sweet_drm`;
    - function-constant values from the Metal device (`rwa_set_function_constants`);
    - the delta constant buffer kept below Panfrost's base;
    - freedreno's debug flag only where freedreno is linked;
    - pointer locals kept at translation time (`AIR_VAL_SLOT`), including a constant `metal::sampler` struct and a zero `getelementptr` or `bitcast` of one;
    - pointer members of a scratch initializer left zero.
    - after the first phone run: the null texture reads zeros and drops writes (QuartzCore's off colour cube); a buffer the shader declares and the encoder left unbound reads a device buffer of zeros (QuartzCore's `config_buffer`); `rwa_shader_cache_sync` waits for Mesa's cache writes; `air2nir` takes function constant values from `AIR_FC`.
    - after the second phone run: an API sampler the shader declares and the encoder left unbound gets the device's default sampler state (QuartzCore's `img_samp_0/1`).
- The port was done with a script kept in the session notes, which asserts every anchor. The `AIR_VAL_SLOT` and initializer changes were made by hand afterwards.

## What it was checked against

- **iOS 16.7's QuartzCore `default.metallib`, locally only** (Apple's file never leaves the machine), `air2nir --report`:
  - this copy translates 139 of its 141 functions;
  - Chlorophyll's copy alone translates 137, and the S9+ copy 135;
  - the two `fixed_frag_*` ubershaders now translate; the two left are `tile_downsample_4/8`, tile kernels that need imageblocks (Apple4 and up, which the A04s device does not claim).
- **On CI, `check.sh`** runs M1's checks over it: the hand-written AIR modules and our own Metal shaders on Panfrost as the Mali-G52 under drm-shim, and pandecode on every job chain.
