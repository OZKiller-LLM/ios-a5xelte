#!/bin/bash
# Galaxy A04s, Metal track M5: libhakiosair for the phone's iOS 16 (arm64, iPhoneOS SDK).
#
# The library M1 checked under the shim (gpu/a04s/metal/check.sh), built for the device: Mesa
# 25.0.7 with the AIR (Metal) front end and libhakiosair (gpu/a04s/metal/air since M6: Chlorophyll's
# copy with the S9+ copy's Panfrost changes and the A04s's; see air/NOTICE.md),
# Gallium Panfrost for the Mali-G52 and softpipe. Panfrost reaches the GPU as it does in the 7c-6
# route: through gpu/mesa/herodrm.c, the libdrm stand-in over HeroGPU, with gpu/mesa/patch-mesa.py's
# Mesa changes for it. HakiOS's own Darwin patches (panfrost-darwin, freedreno-darwin) are left
# out: they are for the Panfrost-shaped kernel interface (7c-7), not HeroGPU.
#
#   gpu/a04s/metal/m5/build-mesa-ios.sh WORK OUT      (macOS with Xcode)
#
# OUT gets libhakiosair.dylib and libdrm.2.dylib, install names @rpath/..., ad-hoc signed.
# Nothing of Apple's is in OUT.
set -euo pipefail

WORK=$(mkdir -p "$1" && cd "$1" && pwd)
OUT=$(mkdir -p "$2" && cd "$2" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
METAL=$(cd "$HERE/.." && pwd)
HK=$METAL/hakios
GPU_MESA=$(cd "$METAL/../../mesa" && pwd)
VERSION=25.0.7
SHA256=592272df3cf01e85e7db300c449df5061092574d099da275d19e97ef0510f8a6
LIBDRM_TAG=libdrm-2.4.124
MIN_IOS=16.0
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC_IOS="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=$MIN_IOS -isysroot $SDK"

cd "$WORK"
[ -f mesa-$VERSION.tar.xz ] || curl -sL --fail -o mesa-$VERSION.tar.xz https://archive.mesa3d.org/mesa-$VERSION.tar.xz
echo "$SHA256  mesa-$VERSION.tar.xz" | shasum -a 256 -c --quiet
[ -d libdrm ] || git clone -q --depth 1 --branch "$LIBDRM_TAG" https://gitlab.freedesktop.org/mesa/drm.git libdrm

# The source tree, made again whenever an input changed.
STAMP=$(cat "$GPU_MESA/patch-mesa.py" "$GPU_MESA/hero_hw.c" "$GPU_MESA/osmesa_hero.inc" \
	"$HK"/mesa/patches/air-frontend.patch "$HK"/mesa/patches/air-metal.patch \
	"$HK"/mesa/patches/panfrost-pack-pointer.patch "$METAL"/mesa-patches/*.patch \
	"$METAL"/air/* "$HERE/patch-pan-disk-cache.py" "$HERE/build-mesa-ios.sh" | shasum -a 256 | cut -d' ' -f1)
if [ "$(cat mesa/.a04s-m5 2>/dev/null)" != "$STAMP" ]; then
	rm -rf mesa build
	tar xJf mesa-$VERSION.tar.xz
	mv mesa-$VERSION mesa
	# 1. HeroGPU's libdrm stand-in: BO maps through herodrm_mmap, libdrm on Darwin (the 7c-6 route)
	python3 "$GPU_MESA/patch-mesa.py" mesa
	# 2. HakiOS's AIR front end and the libhakiosair target, and a macro fix in Panfrost's genxml
	for p in air-frontend air-metal panfrost-pack-pointer; do
		patch -s --no-backup-if-mismatch -d mesa -p1 < "$HK/mesa/patches/$p.patch"
	done
	# 3. the A04s's own Mesa patches (the Bifrost CLPER fix of M1c)
	for p in "$METAL"/mesa-patches/*.patch; do
		patch -s --no-backup-if-mismatch -d mesa -p1 < "$p"
	done
	# 4. M6: Panfrost's shader cache without an ELF build-id
	python3 "$HERE/patch-pan-disk-cache.py" mesa
	rm -rf mesa/src/compiler/air
	cp -R "$METAL/air" mesa/src/compiler/air   # M6: the merged front end and library (air/NOTICE.md)
	echo "$STAMP" > mesa/.a04s-m5
fi

# The libdrm stand-in, and a pkg-config file pointing Mesa at it (as gpu/mesa/build-mesa.sh).
mkdir -p drm-standin pc
$CC_IOS -O2 -Wall -fvisibility=hidden -dynamiclib \
	-install_name @rpath/libdrm.2.dylib \
	-I libdrm -I libdrm/include/drm -I mesa/include \
	-o drm-standin/libdrm.2.dylib "$GPU_MESA/herodrm.c" \
	-framework IOKit -framework CoreFoundation
ln -sf libdrm.2.dylib drm-standin/libdrm.dylib
# M6: the iPhoneOS SDK's own zlib, for Mesa's shader cache (compressed entries)
cat > pc/zlib.pc <<EOF
Name: zlib
Description: zlib of the iPhoneOS SDK
Version: 1.2.12
Libs: -lz
Cflags:
EOF
cat > pc/libdrm.pc <<EOF
Name: libdrm
Description: HeroGPU libdrm stand-in
Version: ${LIBDRM_TAG#libdrm-}
Cflags: -I$WORK/libdrm -I$WORK/libdrm/include/drm
Libs: -L$WORK/drm-standin -ldrm
EOF

cat > ios-cross.txt <<EOF
[binaries]
c = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
cpp = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-arch', 'arm64']
objc = ['xcrun', '--sdk', 'iphoneos', 'clang', '-arch', 'arm64']
ar = ['xcrun', '--sdk', 'iphoneos', 'ar']
strip = ['xcrun', '--sdk', 'iphoneos', 'strip']
ranlib = ['xcrun', '--sdk', 'iphoneos', 'ranlib']
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
cpp_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
objc_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
c_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
cpp_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']
objc_link_args = ['-miphoneos-version-min=$MIN_IOS', '-isysroot', '$SDK']

[properties]
needs_exe_wrapper = true
pkg_config_libdir = '$WORK/pc'

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

# Release, as the phone's OSMesa is built; softpipe stays in for RWA_SOFTWARE=1 (the probe's
# reference run). No OSMesa: nothing here draws through OpenGL. M6: Mesa's shader cache on
# (Panfrost keeps its compiled shaders; the device points MESA_SHADER_CACHE_DIR at
# /private/var/a04s/mesa-cache), with the SDK's zlib.
[ -f build/build.ninja ] || meson setup build mesa --cross-file ios-cross.txt \
	--buildtype=release -Db_ndebug=true -Dprefix=/ \
	-Dgallium-drivers=softpipe,panfrost -Dvulkan-drivers= \
	-Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= \
	-Dosmesa=false -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dshared-glapi=enabled \
	-Dshader-cache=enabled -Dzlib=enabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled \
	-Dxmlconfig=disabled -Dexpat=disabled -Dbuild-tests=false -Dglvnd=disabled -Dlmsensors=disabled \
	-Dgallium-opencl=disabled -Dgallium-rusticl=false -Dgallium-xa=disabled \
	-Dgallium-vdpau=disabled -Dgallium-va=disabled -Dtools= -Dperfetto=false -Dvideo-codecs=
ninja -C build src/gallium/targets/hakiosair/libhakiosair.dylib

cp build/src/gallium/targets/hakiosair/libhakiosair.dylib "$OUT/libhakiosair.dylib"
cp drm-standin/libdrm.2.dylib "$OUT/libdrm.2.dylib"
xcrun strip -x "$OUT/libhakiosair.dylib"
install_name_tool -id @rpath/libhakiosair.dylib "$OUT/libhakiosair.dylib"
for dep in $(otool -L "$OUT/libhakiosair.dylib" | awk 'NR > 1 { print $1 }'); do
	case "$dep" in
	/usr/lib/*|/System/*|@rpath/*) ;;
	*) install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$OUT/libhakiosair.dylib" ;;
	esac
done
for f in "$OUT"/*.dylib; do
	codesign -s - -f "$f"
	otool -L "$f"
done
# what the library exports to the Metal device, for the record
xcrun --sdk iphoneos nm -gU "$OUT/libhakiosair.dylib" | grep ' _rwa_' | wc -l
ls -la "$OUT"
