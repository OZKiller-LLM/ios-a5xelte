#!/bin/bash
# Galaxy A04s, Metal track M1: the Metal shader path and Panfrost's job chains for the Mali-G52
# (Bifrost v7, GPU_ID 0x7212, one shader core), checked on a Linux machine without the phone.
#
# Adapted from the Galaxy S9+ port's tools/mali-drmshim-check.sh (github.com/danstronics/
# ios-s9plus-exynos at 2d09239, core/, MIT; reuse for other ports OK'd by its author). What is
# vendored from it is in hakios/ with its LICENSE; see README.md for the list.
#
# Mesa 25.0.7 (the release gpu/a04s/shaderc and gpu/mesa use) is built with HakiOS's patches, the
# AIR (Metal) front end in src/compiler/air and libhakiosair (air_metal.c), Gallium Panfrost,
# softpipe and Mesa's drm-shim. Panfrost then runs under hakios_mali_shim.c in place of a GPU,
# answering as a Mali-G52 MP1 with the registers the phone reported (GPU_ID 0x7212, L2_FEATURES
# 0x07100206, SC 1, L2 1). Nothing runs the jobs; what is checked is everything up to the GPU:
#
#   1. Metal: hand-written AIR modules (hakios/air/*.ll, none of them Apple's) through libhakiosair
#      onto Panfrost: AIR -> NIR -> Panfrost's Bifrost v7 compiler -> job chains. Each pipeline must
#      compile and build chains; PAN_MESA_DEBUG=trace has Mesa's pandecode write every chain, and
#      hakios/mali-drmshim/pandecode-check.py judges them (no decoder complaints, every pointer in
#      a buffer the shim gave, shader code in an executable one).
#   2. OpenGL ES: a triangle and fills through OSMesa on Panfrost as the G52, judged the same way
#      (the 7c-6 route's userland, off the phone), and the same frames on softpipe compared with
#      the picture kept from the S9 port.
#
# What this does NOT prove: that the G52 runs these chains, that the registers the shim reports
# beyond the four read on the phone are this G52's (the rest are the shim's documented
# assumptions), or anything of the kernel's half.
#
#   gpu/a04s/metal/check.sh BUILD_DIR OUT_DIR
#
# Needs: curl, xz, a C compiler, python3 with venv, ninja, bison, flex, libdrm's headers,
# llvm-as. About 1 GB in BUILD_DIR. Exit 0: everything passed.
set -e
SELF=$(readlink -f "$0")
HERE=$(dirname "$SELF")
HK=$HERE/hakios
VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
B=$(mkdir -p "$1" && cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
SRC=$B/mesa-$VERSION
LLVM_AS=${LLVM_AS:-$(command -v llvm-as || ls /usr/lib/llvm-*/bin/llvm-as 2>/dev/null | tail -1)}

# The Mali-G52 MP1 of the Galaxy A04s, as the phone reported it: GPU ID 72120000, L2F 7100206,
# SC 1, L2 1 (runbook, 7c-2 and 7c-5b), and HeroGPU's GetParam after 7c-6 (2026-11-07): JS_PRESENT
# 7, MMU_FEATURES 0x2830, MAX_THREADS 0x300, THREAD_TLS_ALLOC 0 and AFBC_FEATURES 0. Everything
# else stays the shim's stated assumption.
export HAKIOS_MALI_REGS=${HAKIOS_MALI_REGS:-prod_id=0x7212,revision=0x0,shader_present=0x1,l2_present=0x1,l2_features=0x07100206,js_present=0x7,mmu_features=0x2830,max_threads=0x300,tls_alloc=0x0,afbc_features=0x0}

cd "$B"
# The sources: the release, every HakiOS Mesa patch in name order (as the S9 port applies them),
# then the S9 script's three changes for a Linux build machine (an IOSurface call fenced off with
# __APPLE__, glibc 2.43's call_once, the shim as one more drm-shim library).
# Then the A04s's own Mesa patches (mesa-patches/, ours), in name order.
PATCHES=$(cat "$HK"/mesa/patches/*.patch "$HERE"/mesa-patches/*.patch "$HERE"/air/* "$SELF" | sha256sum | cut -d' ' -f1)
if [ ! -d "$SRC" ] || [ "$(cat "$SRC/.a04s-patches" 2>/dev/null)" != "$PATCHES" ]; then
	[ -f mesa-$VERSION.tar.xz ] || curl -sL --fail -o mesa-$VERSION.tar.xz https://archive.mesa3d.org/mesa-$VERSION.tar.xz
	echo "$SHA256  mesa-$VERSION.tar.xz" | sha256sum -c --quiet
	rm -rf "$SRC" build
	tar xJf mesa-$VERSION.tar.xz
	for p in "$HK"/mesa/patches/*.patch; do patch -s --no-backup-if-mismatch -d "$SRC" -p1 < "$p"; done
	for p in "$HERE"/mesa-patches/*.patch; do patch -s --no-backup-if-mismatch -d "$SRC" -p1 < "$p"; done
	cp -r "$HK/mesa/hakios-drm" "$SRC/src/hakios-drm"
	python3 - "$SRC" <<-'PY'
		import sys
		root = sys.argv[1]
		p = root + '/src/gallium/targets/osmesa/osmesa_target.c'
		s = open(p).read()
		old = "{\n#ifdef OSMESA_GPU\n   struct hakios_drm_surface"
		assert old in s, 'osmesa_target.c is not as panfrost-darwin.patch leaves it'
		open(p, 'w').write(s.replace(old, "{\n#if defined(OSMESA_GPU) && defined(__APPLE__)\n   struct hakios_drm_surface"))
		p = root + '/src/c11/threads.h'
		s = open(p).read()
		old = "typedef pthread_once_t  once_flag;\n#  define ONCE_FLAG_INIT PTHREAD_ONCE_INIT\n"
		new = ("#  if defined(__GLIBC__) && __GLIBC_USE(ISOC23) && !defined(__cplusplus)\n"
		       "#    define C11_LIBC_HAS_CALL_ONCE 1\n#  else\n"
		       "typedef pthread_once_t  once_flag;\n#    define ONCE_FLAG_INIT PTHREAD_ONCE_INIT\n#  endif\n")
		if old in s:
		    open(p, 'w').write(s.replace(old, new))
		p = root + '/src/c11/impl/threads_posix.c'
		s = open(p).read()
		old = "call_once(once_flag *flag, void (*func)(void))\n{\n    pthread_once(flag, func);\n}\n"
		if old in s and 'C11_LIBC_HAS_CALL_ONCE' not in s:
		    i = s.index(old)
		    j = s.rfind('\n\n', 0, i)
		    s = (s[:j] + "\n\n#ifndef C11_LIBC_HAS_CALL_ONCE" + s[j:i + len(old)] + "#endif\n" + s[i + len(old):])
		    open(p, 'w').write(s)
		with open(root + '/src/panfrost/drm-shim/meson.build', 'a') as f:
		    f.write("\n# HakiOS's HakiosMali shim, here answering as the Galaxy A04s's Mali-G52\n"
		            "libhakios_mali_drm_shim = shared_library(\n"
		            "  'hakios_mali_drm_shim',\n  'hakios/hakios_mali_shim.c',\n"
		            "  include_directories: [inc_include, inc_src, include_directories('hakios')],\n"
		            "  dependencies: dep_drm_shim,\n  gnu_symbol_visibility : 'hidden',\n)\n")
	PY
	rm -rf "$SRC/src/compiler/air"
	cp -r "$HERE/air" "$SRC/src/compiler/air"   # M6: the merged front end and library (air/NOTICE.md)
	# M6b: the front end's identity, for its cache of translated stages (as m5/build-mesa-ios.sh)
	echo "#define A04S_AIR_FRONT_ID \"$(cat "$HERE"/air/* | sha256sum | cut -c1-32)\"" > "$SRC/src/compiler/air/air_front_id.h"
	mkdir -p "$SRC/src/panfrost/drm-shim/hakios"
	cp "$HK/mali-drmshim/hakios_mali_shim.c" "$HK/hakios.mali_va.h" "$SRC/src/panfrost/drm-shim/hakios/"
	echo "$PATCHES" > "$SRC/.a04s-patches"
fi

if [ ! -x venv/bin/meson ]; then
	python3 -m venv venv
	venv/bin/pip -q install meson mako pyyaml packaging
fi
export PATH=$B/venv/bin:$PATH

# The S9 script's options: assertions on (debugoptimized), drm-shim and Panfrost's tools, no LLVM
# (softpipe, as on the phone), nothing of Darwin's.
[ -f build/build.ninja ] || meson setup build "$SRC" --buildtype=debugoptimized \
	-Dplatforms= -Dgallium-drivers=softpipe,panfrost -Dvulkan-drivers= \
	-Dglx=disabled -Degl=disabled -Dgbm=disabled -Dosmesa=true -Dllvm=disabled -Dshared-glapi=enabled \
	-Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dzstd=disabled -Dxmlconfig=disabled -Dexpat=disabled \
	-Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dglvnd=disabled -Dvideo-codecs= \
	-Dtools=drm-shim,panfrost -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dgallium-xa=disabled \
	-Dlmsensors=disabled -Dbuild-tests=false > "$OUT/meson-setup.log"
ninja -C build src/gallium/targets/osmesa/libOSMesa.so.8.0.0 src/panfrost/drm-shim/libhakios_mali_drm_shim.so \
	src/gallium/targets/hakiosair/air_metal_test src/compiler/air/air2nir > "$OUT/ninja.log"

rm -rf "$OUT/gl" "$OUT/air"
mkdir -p "$OUT/gl" "$OUT/air"
cc -O1 -Wall -o "$OUT/gl_drmshim" "$HK/mali-drmshim/gl_drmshim.c" -I"$SRC/include" \
	-L"$B/build/src/gallium/targets/osmesa" -lOSMesa
export LD_LIBRARY_PATH=$B/build/src/gallium/targets/osmesa:$B/build/src/mapi/shared-glapi
SHIM=$B/build/src/panfrost/drm-shim/libhakios_mali_drm_shim.so
AMT=$B/build/src/gallium/targets/hakiosair/air_metal_test
A2N=$B/build/src/compiler/air/air2nir
CHECK=$HK/mali-drmshim/pandecode-check.py
FAILED=0
fail() { echo "a04s-metal-check: FAIL: $*"; FAILED=$((FAILED + 1)); }

on_mali() {
	local dir=$1
	shift
	mkdir -p "$dir"
	RWA_SOFTWARE=0 HAKIOS_MALI_SHIM_TRACE=$dir/shim.trace PAN_MESA_DEBUG=trace \
		PANDECODE_DUMP_FILE=$dir/pandecode.dump LD_PRELOAD=$SHIM "$@" > "$dir/stdout.log" 2> "$dir/stderr.log"
}
judge() {
	local dir=$1 what=$2
	grep -h '^hakios-mali-shim:' "$dir/stderr.log" | sed "s/^/$what: /"
	grep -q '^hakios-mali-shim: contract kept' "$dir/stderr.log" || fail "$what: the shim's contract line"
	python3 "$CHECK" "$dir" "$dir/shim.trace" "$dir/stderr.log" | sed "s/^/$what: /"
	python3 "$CHECK" "$dir" "$dir/shim.trace" "$dir/stderr.log" > /dev/null || fail "$what: pandecode-check"
}

echo "== Metal: hand-written AIR modules through libhakiosair onto Panfrost, as the Mali-G52"
for ll in "$HK"/air/*.ll; do
	name=$(basename "$ll" .ll)
	"$LLVM_AS" -o "$OUT/air/$name.bc" "$ll"
	# the front end alone: AIR -> NIR, kept for reading
	"$A2N" "$OUT/air/$name.bc" > "$OUT/air/$name.nir.txt" 2>&1 || fail "air2nir $name"
done
cd "$OUT/air"
run_metal() {
	local name=$1
	shift
	set +e
	on_mali "$name" "$AMT" "$@"
	local rc=$?
	RWA_SOFTWARE=1 "$AMT" "$@" > "$name/softpipe.log" 2>&1
	local soft=$?
	set -e
	local chains
	chains=$(sed -n 's/.* \([0-9]*\) chains submitted.*/\1/p' "$name/stderr.log")
	if grep -q 'Assertion\|rwa_device_open:\|would not make' "$name/stdout.log" "$name/stderr.log" || [ "${chains:-0}" = 0 ]; then
		fail "Metal $name: not compiled, or no chain (exit $rc): $(grep -h 'Assertion\|rwa_\|would not' "$name/stdout.log" "$name/stderr.log" | head -2)"
	else
		echo "Metal $name: compiled for the G52, ${chains} chains built (exit $rc; what it read back is not a result); softpipe exit $soft"
	fi
	judge "$name" "Metal $name"
}
run_metal phiconst phiconst.bc
run_metal fragpos --draw fragpos.bc fragPos 125
run_metal argbuf --draw-argbuf argbuf_set.bc argbuf_direct.bc

# M6b: the front end's cache of translated stages (air_metal.c, front_to_nir). The same draw twice in a fresh cache
# folder: the first translates its stage and writes it, the second must read it back instead, and both must build the
# same chains (pandecode's dumps compared, addresses and all).
FC=$OUT/air/front-cache
rm -rf "$FC" fc-miss fc-hit
mkdir -p "$FC"
export A04S_AIR_CACHE_DIR=$FC RWA_AIR_CACHE_LOG=1
set +e
on_mali fc-miss "$AMT" --draw fragpos.bc fragPos 125
on_mali fc-hit "$AMT" --draw fragpos.bc fragPos 125
set -e
unset A04S_AIR_CACHE_DIR RWA_AIR_CACHE_LOG
stored=$(ls "$FC/a04s-air" 2>/dev/null | grep -c '\.bin$' || true)
misses=$(grep -c '^rwa: front cache miss' fc-miss/stderr.log || true)
hits=$(grep -c '^rwa: front cache hit' fc-hit/stderr.log || true)
hit_misses=$(grep -c '^rwa: front cache \(miss\|unreadable\)' fc-hit/stderr.log || true)
echo "Metal front-end cache: first run $misses miss(es), $stored file(s) written; second run $hits hit(s), $hit_misses miss(es)"
[ "$misses" -ge 1 ] && [ "$stored" -ge 1 ] && [ "$hits" -ge 1 ] && [ "$hit_misses" = 0 ] ||
	fail "Metal front-end cache: expected a miss and a write, then only hits"
# pandecode writes one file per frame (pandecode.dump.NNNN). Its "Shader <CPU address> (GPU VA ...)" lines name where
# each process mapped the code, which ASLR moves between runs; that address is masked, the GPU addresses are not.
cat fc-miss/pandecode.dump* 2>/dev/null | sed -E 's/^Shader 0x[0-9a-f]+ \(/Shader <cpu> (/' > fc-miss.dump || true
cat fc-hit/pandecode.dump* 2>/dev/null | sed -E 's/^Shader 0x[0-9a-f]+ \(/Shader <cpu> (/' > fc-hit.dump || true
if [ -s fc-miss.dump ] && cmp -s fc-miss.dump fc-hit.dump; then
	echo "Metal front-end cache: the cached stage built the same chains ($(wc -l < fc-hit.dump) lines of pandecode, identical)"
else
	fail "Metal front-end cache: the chains differ between the translated and the cached stage, or none were dumped ($(diff fc-miss.dump fc-hit.dump | head -3 | tr '\n' ' '))"
fi
judge fc-hit "Metal front-end cache (cached run)"
cd "$OUT"

# M1b: our own Metal shaders (shaders/*.metal), compiled by Apple's Metal compiler on a macOS
# runner into METALLIBS (core.metallib, probe.metallib), as iOS 16's own libraries are built.
# The core functions must pass; a probe's outcome is recorded either way.
probe() {
	local name=$1
	shift
	set +e
	on_mali "$name" "$AMT" "$@"
	local rc=$?
	set -e
	local chains why
	chains=$(sed -n 's/.* \([0-9]*\) chains submitted.*/\1/p' "$name/stderr.log")
	if grep -q 'Assertion' "$name/stdout.log" "$name/stderr.log" || [ "${chains:-0}" = 0 ]; then
		why=$(grep -h -i 'refus\|not handled\|not implemented\|unsupported\|would not\|Assertion\|error' \
			"$name/stdout.log" "$name/stderr.log" | head -2 | cut -c1-300 | tr '\n' ' ')
		echo "Probe $name: NOT YET (exit $rc): ${why:-no chain built}"
	elif python3 "$CHECK" "$name" "$name/shim.trace" "$name/stderr.log" > "$name/pandecode-check.log"; then
		echo "Probe $name: compiled for the G52, ${chains} chains built, pandecode-check PASS"
	else
		echo "Probe $name: compiled, ${chains} chains, pandecode-check FAILED: $(tail -1 "$name/pandecode-check.log")"
	fi
}
if [ -n "${METALLIBS:-}" ]; then
	echo "== Metal, Apple-compiled: our shaders from Apple's Metal compiler, onto Panfrost as the Mali-G52"
	mkdir -p "$OUT/apple"
	cd "$OUT/apple"
	for lib in "$METALLIBS"/*.metallib; do
		echo "-- $(basename "$lib"): the front end alone (air2nir --report)"
		"$A2N" --report "$lib" 2>&1 | sed 's/^/   /' | cut -c1-300 || true
	done
	CORE=$METALLIBS/core.metallib
	PROBE=$METALLIBS/probe.metallib
	run_metal m1b_fill_buffer "$CORE" fill_buffer
	run_metal m1b_gradient_fs --draw "$CORE" gradient_fs 125
	run_metal m1b_quad_uv --draw-vertex "$CORE" quad_vs uv_fs 125
	probe m1b_half_scale "$CORE" half_scale
	probe m1b_tex_gradient "$CORE" tex_gradient 125
	probe m1b_group_sum "$CORE" group_sum
	probe m1b_blit --draw-vertex "$CORE" quad_vs blit_fs 125
	probe m1b_blit_const --draw-vertex "$CORE" quad_vs blit_const_fs 125
	probe p_fbfetch --draw-vertex "$PROBE" quad_vs_p fbfetch_fs 125
	probe p_const --draw "$PROBE" const_fs 125
	probe p_simd_sum "$PROBE" simd_sum_k
	# M1c: what reaches Bifrost's packer for the SIMD-group sum (CLPER's source port)
	"$A2N" "$PROBE" simd_sum_k > "$OUT/apple/simd_sum_k.nir.txt" 2>&1 || true
	set +e
	BIFROST_MESA_DEBUG=shaders on_mali p_simd_sum_ir "$AMT" "$PROBE" simd_sum_k
	BIFROST_MESA_DEBUG=noopt on_mali p_simd_sum_noopt "$AMT" "$PROBE" simd_sum_k
	echo "Probe p_simd_sum with BIFROST_MESA_DEBUG=noopt: $(grep -h 'chains submitted\|Assertion' p_simd_sum_noopt/stderr.log p_simd_sum_noopt/stdout.log | head -2 | cut -c1-200 | tr '\n' ' ')"
	set -e
	probe p_atomic "$PROBE" atomic_count
	probe p_half_read --draw "$PROBE" half_read_fs 125
	cd "$OUT"
fi

echo "== OpenGL ES on Panfrost, as the Mali-G52 (the 7c-6 route's userland)"
if on_mali "$OUT/gl/mali" "$OUT/gl_drmshim" 720 1600 "$OUT/gl/mali/readback.rgba" fill; then
	grep '^gl_drmshim: Mesa' "$OUT/gl/mali/stdout.log" || true
	grep -q 'Mali-G52' "$OUT/gl/mali/stdout.log" || fail "GL: not Panfrost as a Mali-G52"
	grep -q 'one with a blend shader; error 0' "$OUT/gl/mali/stdout.log" || fail "GL: a GL error"
else
	fail "GL on Panfrost exited $?"
fi
judge "$OUT/gl/mali" GL

echo "== OpenGL ES on softpipe: the S9 port's kept picture (1080 x 2400)"
OSMESA_SOFTWARE=1 "$OUT/gl_drmshim" 1080 2400 "$OUT/gl/softpipe.rgba" > "$OUT/gl/softpipe.log"
want=$(cut -d' ' -f1 "$HK/mali-drmshim/gl_test-1080x2400-softpipe.sha256")
got=$(sha256sum < "$OUT/gl/softpipe.rgba" | cut -d' ' -f1)
if [ "$want" = "$got" ]; then
	echo "softpipe: the picture is the one kept (sha256 $got)"
else
	fail "softpipe drew a picture other than the one kept ($got)"
fi

echo
if [ "$FAILED" = 0 ]; then
	echo "a04s-metal-check: PASS (everything in $OUT)"
else
	echo "a04s-metal-check: $FAILED FAILED (everything in $OUT)"
	exit 1
fi
