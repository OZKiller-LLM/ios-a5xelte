#!/usr/bin/env bash
# Galaxy A04s, stage 7c-4c: build Mesa 25.0.7's Panfrost compiler on a Linux host and run
# a04s_shaderc, which writes the Mali-G52's shaders to OUT (see a04s_shaderc.c).
# Usage: gpu/a04s/shaderc/build.sh WORKDIR OUTDIR (from the repository root).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mkdir -p "$1" && cd "$1" && pwd)"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
mesa="$work/mesa"

if [ ! -d "$mesa" ]; then
  git clone -q --depth 1 --branch mesa-25.0.7 https://gitlab.freedesktop.org/mesa/mesa.git "$mesa"
fi
echo "mesa $(git -C "$mesa" rev-parse HEAD)"

# The tool sits next to pan_shader.c and links Panfrost's own libraries (libpanfrost_dep).
cp "$here/a04s_shaderc.c" "$mesa/src/panfrost/lib/a04s_shaderc.c"
if ! grep -q a04s_shaderc "$mesa/src/panfrost/lib/meson.build"; then
  cat "$here/meson.snippet" >> "$mesa/src/panfrost/lib/meson.build"
fi

cd "$mesa"
# The S7's Mesa options (gpu/mesa/build-mesa.sh) on a native host: Gallium Panfrost with no
# window system, no LLVM, nothing installed. Only the compiler and this tool are built.
[ -d build ] || meson setup build \
  --buildtype=release -Db_ndebug=true -Dprefix=/ \
  -Dgallium-drivers=softpipe,panfrost -Dvulkan-drivers= \
  -Dllvm=disabled -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dplatforms= \
  -Dosmesa=true -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dshared-glapi=enabled \
  -Dshader-cache=disabled -Dvalgrind=disabled -Dlibunwind=disabled -Dzstd=disabled \
  -Dxmlconfig=disabled -Dbuild-tests=false -Dglvnd=disabled -Dlmsensors=disabled \
  -Dgallium-opencl=disabled -Dgallium-rusticl=false -Dgallium-xa=disabled \
  -Dgallium-vdpau=disabled -Dgallium-va=disabled -Dtools= -Dperfetto=false
ninja -C build src/panfrost/lib/a04s_shaderc

./build/src/panfrost/lib/a04s_shaderc "$out"
(cd "$out" && sha256sum ./*.bin ./*.h | tee SHA256SUMS)
