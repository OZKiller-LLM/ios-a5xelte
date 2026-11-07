# gpu/a04s/metal: the Galaxy A04s's native Metal driver (parallel track)

The Metal driver for the A04s's Mali-G52 (Bifrost v7, GPU_ID 0x7212, one shader core) is developed beside the main track (7c-6, then 6b, then performance), as the owner decided on 2026-11-07.
- The plan is in the session folder's `metal-driver-parallel-plan.md`, packages M1 to M6.
- The interface map is `metal-driver-step1.md`.

This folder holds only off-phone work. Nothing here touches the A04s kernel or its builds.

## M1: the shader path and Panfrost's job chains, checked without the phone

`check.sh BUILD_DIR OUT_DIR` (CI: `.github/workflows/a04s-metal.yml`):
1. Builds Mesa 25.0.7 with HakiOS's Metal shader front end (AIR → NIR, `src/compiler/air`), `libhakiosair`, Gallium Panfrost, softpipe and Mesa's drm-shim.
2. Runs Panfrost under a shim that answers as the A04s's Mali-G52, with GPU_ID 0x7212, L2_FEATURES 0x07100206, one shader core and one L2, as the phone reported them. The shim's other registers are its documented assumptions.
3. Metal: hand-written AIR modules (`hakios/air/*.ll`, none of them Apple's) go through AIR → NIR → Panfrost's Bifrost compiler into job chains. Each must compile and build chains. Mesa's pandecode writes every chain, and `pandecode-check.py` judges it: no decoder complaints, every pointer inside a buffer the shim gave, shader code in executable memory.
4. OpenGL ES: OSMesa on Panfrost as the G52 (the userland of the 7c-6 route, off the phone), judged the same way, plus a softpipe picture compared with the one kept from the S9+ port.

## M1b: our own Metal shaders, compiled by Apple's compiler

`shaders/core.metal` and `shaders/probe.metal` are this repository's own shaders.
- **Compilation:** the CI's macOS job compiles them with the iPhoneOS SDK's `metal` (MSL 3.0, iOS 16 deployment target, as iOS 16.7's libraries are built). The Linux job feeds the metallibs through the same path (`METALLIBS=dir check.sh ...`).
- **Core functions must pass:** a buffer kernel, a fragment shader reading `[[position]]`, and a vertex/fragment pair with a varying.
- **The rest are probes:** half precision, texture writes, threadgroup memory, sampling with a sampler and a constexpr sampler, framebuffer fetch, function constants, SIMD-group functions, atomics, `half` texture reads. Each result is printed as "compiled, N chains, pandecode-check PASS" or "NOT YET" with the refusal, without failing the run.

**First results (CI run 42316582117):**
- All 15 functions translate.
- The three core pairs pass.
- Of the probes, these compile to chains that pass pandecode-check: half, samplers (constexpr too), framebuffer fetch, a function constant, atomics, and `half` texture reads.
- Not yet: a kernel's texture write (a Bifrost compiler assertion on the image store's type), threadgroup memory (the test doesn't dispatch it yet) and `simd_sum` (a Bifrost packer assertion on v7).

**What it does not prove:**
- that the G52 runs these chains (no GPU executes anything);
- that the registers beyond the four read on the phone are right;
- anything about the kernel.

Apple's own metallibs are never used here or in CI. Coverage over iOS's system libraries is run locally only.

## M5: compute, then a triangle, on the G52 (`m5/`)

The first Metal device that computes and draws, run by a probe on the phone. CI: `.github/workflows/a04s-metal-m5.yml`.
- **`m5/build-mesa-ios.sh`:** `libhakiosair` for iOS 16. Mesa 25.0.7 with the AIR front end and `hakios/mesa/air`, Gallium Panfrost and softpipe. It reaches the GPU through `gpu/mesa/herodrm.c` over HeroGPU, the 7c-6 route, with `gpu/mesa/patch-mesa.py`'s changes.
- **The device:** Chlorophyll's `bgmtl.m` (`chlorophyll/`, MIT, see its `NOTICE.md`) compiled into `libA04sMetalDevice.dylib` with `m5/A04sMTLDevice.m`, which adds the A04s's identity from M4. Pipelines compile in-process from `bitcodeData`; Apple's compiler service is never used.
- **The gate:** `m5/A04sMetal.m` is the bundle's executable, as small as M4's. It loads the device library only in a process that asks (`A04S_METAL=1` or `/private/var/a04s/metal.clients`), never in backboardd, and not when `a04smetal.off` is in the bundle.
- **The probe:** `m5/a04s_metal_m5.m` installs the bundle, then runs `fill_buffer` (4096 values), a triangle (`shaders/m5.metal`, vertex and constant buffers) and a quad with a varying. It runs once on softpipe as the reference and once on the Mali-G52, each in a child process, and logs PASS or FAIL per test.
- **`hakios/mesa/air` additions for it**, marked "A04s (Metal track M5)": Chlorophyll's fence calls, render-pass clear, GPU texture copy and mipmaps, and scissor.

## M6a: CoreAnimation's own Metal renderer on the device, in the probe only

- **The library moves to `air/`:** Chlorophyll's newer front end, with the S9+ copy's Panfrost changes and the A04s's ported onto it (`air/NOTICE.md`). Over iOS 16.7's QuartzCore metallib it translates 139 of 141 functions locally, against 135 for the M5 copy, including both `fixed_frag_*` ubershaders. `check.sh` re-runs M1's checks on it in CI.
- **Function constants:** QuartzCore's ubershader is specialised by about 58 constants per pipeline. The device takes over `-[_MTLLibrary newFunctionWithDescriptor:error:]` and `newFunctionWithName:constantValues:error:` for its own libraries, keeps the values with the function, and hands them to the library (`rwa_set_function_constants`) when it builds the pipeline. On iOS 16.7 Metal would otherwise specialise through a compiler the device does not have.
- **Shader cache:** Mesa's disk cache is on (with the SDK's zlib), in `/private/var/a04s/mesa-cache`.
- **Timing:** every pipeline build is logged with its wall and CPU time.
- **IOSurfaces:** textures over IOSurfaces go through `herodrm_surface_import` (CoreAnimation's layer contents), and the GPU's writes are flushed with `herodrm_bo_sync`.
- **The probe** (same autorun) adds `m5/a04s_ca_scenes.m`, Chlorophyll's seven CoreAnimation scenes adapted. Each is drawn by a `CARenderer` on the Metal device and by CoreAnimation's CPU path, compared, and logged as `M6 RESULT`. backboardd is not touched.

## Where `hakios/` comes from

Everything under `hakios/` is copied unchanged from the Galaxy S9+ port, [github.com/danstronics/ios-s9plus-exynos](https://github.com/danstronics/ios-s9plus-exynos) at `2d09239`, directory `core/` (a snapshot of HakiOS/Scion). Its author OK'd reuse for other ports. Its licence, `hakios/LICENSE`, is MIT for userland and tools and APSL-2.0 for kernel-derived files (`hakios/LICENSE.APSL`). Mesa's patches touch Mesa files under Mesa's licences.

| Here | There | Licence |
|---|---|---|
| `hakios/mesa/air/` | `core/tools/mesa/air/` (the AIR front end and `libhakiosair`) | MIT (Darwin on redwood contributors) |
| `hakios/mesa/patches/*.patch` | `core/tools/mesa/*.patch` | patches to Mesa, under Mesa's licences |
| `hakios/mesa/hakios-drm/` | `core/tools/mesa/hakios-drm/` (libdrm over IOKit; on Darwin only) | MIT |
| `hakios/mali-drmshim/` | `core/tools/mali-drmshim/` (the shim, the GL test, pandecode-check) | MIT (Scion-Project contributors) |
| `hakios/air/*.ll` | `core/tools/air/` (hand-written AIR test modules) | MIT |
| `hakios/hakios.mali_va.h` | `core/drivers/gpu/hakios.mali_va.h` (the GPU VA allocator the shim uses) | APSL-2.0 |

`check.sh` is adapted from `core/tools/mali-drmshim-check.sh` (MIT). The changes: the paths, the G52's registers instead of the G72's, and the GL test's size.
