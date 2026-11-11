#!/bin/bash
# Galaxy A04s, Metal track M5: builds the Metal device bundle and the probe for iOS 16 (arm64,
# iPhoneOS SDK), ad-hoc signed, into OUT laid out as the drop zone takes them (paths under
# /private/var/a04s/):
#   OUT/autorun                                   the probe (a04s_metal_m5.m), run once as root
#   OUT/metal/A04sMetal.bundle/A04sMetal          the gate (A04sMetal.m), Metal's plug-in class
#   OUT/metal/A04sMetal.bundle/Info.plist
#   OUT/metal/A04sMetal.bundle/libA04sMetalDevice.dylib   Chlorophyll's device + A04sMTLDevice
#   OUT/metal/A04sMetal.bundle/libhakiosair.dylib         Mesa: AIR -> NIR -> Panfrost/softpipe
#   OUT/metal/A04sMetal.bundle/liba04sdrm.dylib           HeroGPU's libdrm stand-in (an install name of its own, M6b)
#   OUT/metal/core.metallib, OUT/metal/m5.metallib        our own test shaders (../shaders)
# The libraries live inside the bundle because the bundle's folder is what every process that may
# later get a device can read (Chlorophyll's lesson); in M5 only the probe uses them.
#
#   gpu/a04s/metal/m5/build.sh OUT MESA_OUT       (macOS with Xcode; MESA_OUT from build-mesa-ios.sh)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
MESA_OUT=$(cd "$2" && pwd)
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -isysroot $SDK"
CF="-O2 -g -Wall -Wno-unused-function -Wno-deprecated-declarations -fno-objc-arc -I$HERE/../m4 -I$HERE/../air"
B="$OUT/metal/A04sMetal.bundle"
rm -rf "$B"
mkdir -p "$B" "$OUT/metal"

# Metal's private base classes are exported by the device's Metal but not in the SDK's stubs, so
# their class symbols are left to dyld (-U), as M4's bundle did for _MTLDevice.
PRIV=""
for c in _MTLDevice _MTLObjectWithLabel _MTLResource _MTLCommandQueue _MTLCommandBuffer _MTLCommandEncoder \
	_MTLComputePipelineState _MTLRenderPipelineState _MTLSamplerState _MTLDepthStencilState; do
	PRIV="$PRIV -Wl,-U,_OBJC_CLASS_\$_$c -Wl,-U,_OBJC_METACLASS_\$_$c"
done

# the gate: small, Foundation and IOKit only, never linked against the device library
$CC $CF -bundle -o "$B/A04sMetal" "$HERE/A04sMetal.m" -framework Foundation -framework IOKit \
	-Wl,-U,'_OBJC_CLASS_$__MTLDevice' -Wl,-U,'_OBJC_METACLASS_$__MTLDevice'
cp "$HERE/Info.plist" "$B/Info.plist"

# the device, beside the Mesa library and libdrm stand-in it links (@loader_path)
cp "$MESA_OUT/libhakiosair.dylib" "$MESA_OUT/liba04sdrm.dylib" "$B/"
$CC $CF -dynamiclib -o "$B/libA04sMetalDevice.dylib" "$HERE/A04sMTLDevice.m" "$HERE/a04s_bb.m" \
	"$B/libhakiosair.dylib" "$B/liba04sdrm.dylib" \
	-framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation \
	$PRIV -install_name @rpath/libA04sMetalDevice.dylib -Wl,-rpath,@loader_path

# the probe
$CC $CF -o "$OUT/autorun" "$HERE/a04s_metal_m5.m" "$HERE/a04s_ca_scenes.m" "$HERE/a04s_m6_sampling.m" 	-framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics

for s in core m5; do
	xcrun -sdk iphoneos metal -std=metal3.0 -mios-version-min=16.0 \
		-o "$OUT/metal/$s.metallib" "$HERE/../shaders/$s.metal"
done

for f in "$B"/*.dylib "$B/A04sMetal" "$OUT/autorun"; do
	codesign -s - -f "$f"
done
codesign -s - -f "$B" || true

# what each image binds at run time, for the record
for f in "$B/A04sMetal" "$B/libA04sMetalDevice.dylib"; do
	echo "== $(basename "$f"): libraries"
	otool -L "$f"
	echo "== $(basename "$f"): Metal's private classes bound by name"
	xcrun --sdk iphoneos nm -u "$f" | grep '_OBJC_CLASS_\$__MTL' || true
done
echo "== libdrm references (only @rpath/liba04sdrm.dylib; no libdrm.2.dylib)"
otool -L "$B/libhakiosair.dylib" "$B/libA04sMetalDevice.dylib" | grep -i drm
if otool -L "$B/libhakiosair.dylib" "$B/libA04sMetalDevice.dylib" | grep -q "libdrm.2.dylib"; then echo "a library still names libdrm.2.dylib" >&2; exit 1; fi
echo "== libA04sMetalDevice.dylib: rwa_ calls not in libhakiosair (must be none)"
comm -23 <(xcrun --sdk iphoneos nm -u "$B/libA04sMetalDevice.dylib" | grep '^_rwa_' | sort) \
	<(xcrun --sdk iphoneos nm -gU "$B/libhakiosair.dylib" | awk '{print $3}' | grep '^_rwa_' | sort)
ls -la "$OUT" "$OUT/metal" "$B"
(cd "$OUT" && find . -type f ! -name 'SHA256SUMS*' -exec shasum -a 256 {} \; | sort -k2 > SHA256SUMS.tmp && mv SHA256SUMS.tmp SHA256SUMS && cat SHA256SUMS)
