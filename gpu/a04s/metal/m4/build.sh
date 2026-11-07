#!/bin/bash
# Galaxy A04s, Metal track M4: builds the logging Metal device bundle, the logging compiler plug-in
# and the probe for iOS 16 (arm64, iPhoneOS SDK), ad-hoc signed, into OUT laid out as the drop
# zone takes them (paths under /private/var/a04s/):
#   OUT/autorun                               the probe (a04s_metal_probe.m), run once as root
#   OUT/metal/A04sMetal.bundle/{A04sMetal,Info.plist}
#   OUT/lib/A04sMetalCompiler.dylib
#   OUT/metal/core.metallib                   our own test shaders (gpu/a04s/metal/shaders)
#
#   gpu/a04s/metal/m4/build.sh OUT            (on macOS with Xcode)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "$1" && cd "$1" && pwd)
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=16.0 -isysroot $SDK"
CF="-O2 -g -Wall -Wno-unused-function -fno-objc-arc -I$HERE"
mkdir -p "$OUT/metal/A04sMetal.bundle" "$OUT/lib"

# the device: a bundle linked against the device's Metal; _MTLDevice is exported by Metal but not
# in the SDK's stubs, so its class symbols are left to dyld (-U)
$CC $CF -bundle -o "$OUT/metal/A04sMetal.bundle/A04sMetal" "$HERE/A04sMetalDevice.m" \
	-framework Foundation -framework Metal -framework IOKit \
	-Wl,-U,'_OBJC_CLASS_$__MTLDevice' -Wl,-U,'_OBJC_METACLASS_$__MTLDevice'
cp "$HERE/Info.plist" "$OUT/metal/A04sMetal.bundle/Info.plist"

$CC $CF -dynamiclib -o "$OUT/lib/A04sMetalCompiler.dylib" "$HERE/A04sMetalCompiler.c" \
	-install_name /private/var/a04s/lib/A04sMetalCompiler.dylib

$CC $CF -o "$OUT/autorun" "$HERE/a04s_metal_probe.m" -framework Foundation -framework Metal

xcrun -sdk iphoneos metal -std=metal3.0 -mios-version-min=16.0 \
	-o "$OUT/metal/core.metallib" "$HERE/../shaders/core.metal"

for f in "$OUT/metal/A04sMetal.bundle/A04sMetal" "$OUT/lib/A04sMetalCompiler.dylib" "$OUT/autorun"; do
	codesign -s - -f "$f"
done
codesign -s - -f "$OUT/metal/A04sMetal.bundle" || true

# what the bundle binds at run time, for the record
xcrun --sdk iphoneos nm -u "$OUT/metal/A04sMetal.bundle/A04sMetal" | grep -i 'MTL\|IORegistry' || true
(cd "$OUT" && find . -type f -exec shasum -a 256 {} \; | sort -k2 | tee SHA256SUMS)
