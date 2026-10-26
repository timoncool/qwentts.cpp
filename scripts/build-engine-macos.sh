#!/bin/bash
# libqwen.dylib with its ggml libraries for macOS on Apple silicon (the Windows and Linux engines' counterpart), built
# on a Mac from the committed HEAD. ggml's backends are linked in, not modules: the CPU one and Metal with its shader
# library embedded register themselves as ggml starts, so the host asks for the device MTL0 or CPU and loads nothing
# beside the library. No native CPU flags: armv8.2-a with dotprod and fp16, which every Apple silicon processor has.
# Every library finds the others beside itself (install names @rpath, rpath @loader_path).
#   scripts/build-engine-macos.sh <output folder>
# The output folder gets qwen-macos-arm64.tar.gz (the libraries, flat) and its SHA-256.
set -euo pipefail

out="${1:?output folder}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "[..] source $(git -C "$repo" rev-parse --short HEAD)"
git -C "$repo" archive HEAD | tar -x -C "$work"
git -C "$repo" submodule status --recursive | while read -r _ path _; do
  git -C "$repo/$path" archive HEAD | tar -x -C "$work/$path"
done

cmake -S "$work" -B "$work/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DQWEN_SHARED=ON -DBUILD_SHARED_LIBS=ON \
  -DGGML_BACKEND_DL=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=OFF \
  -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_INSTALL_NAME_DIR=@rpath -DCMAKE_BUILD_WITH_INSTALL_NAME_DIR=ON \
  -DCMAKE_BUILD_RPATH=@loader_path -DCMAKE_INSTALL_RPATH=@loader_path >/dev/null
echo "[..] build"
cmake --build "$work/build" --target qwen -j "$(( $(sysctl -n hw.ncpu) * 3 / 4 ))" 2>&1 | tail -3

stage="$work/stage"
mkdir -p "$stage"
cp -L "$(find "$work/build" -name 'libqwen.dylib' -print -quit)" "$stage/"
# the ggml libraries libqwen names by @rpath, each by the name the loader asks for, and those they name in turn
pending=("$stage/libqwen.dylib")
while [ ${#pending[@]} -gt 0 ]; do
  lib="${pending[0]}"
  pending=("${pending[@]:1}")
  for dep in $(otool -L "$lib" | awk 'NR > 1 && $1 ~ /^@rpath\// { sub("@rpath/", "", $1); print $1 }'); do
    [ -f "$stage/$dep" ] && continue
    src="$(find "$work/build" -name "$dep" -print -quit)"
    [ -n "$src" ] || { echo "[ERROR] $lib names @rpath/$dep, which the build did not make"; exit 1; }
    cp -L "$src" "$stage/$dep"
    pending+=("$stage/$dep")
  done
done

for f in "$stage"/*.dylib; do
  echo "$(basename "$f"): $(otool -L "$f" | awk 'NR > 1 { print $1 }' | tr '\n' ' ')"
  if otool -L "$f" | awk 'NR > 1 { print $1 }' | grep -vE '^(@rpath/|/usr/lib/|/System/Library/)'; then
    echo "[ERROR] $(basename "$f") names a library outside @rpath and the system"
    exit 1
  fi
  if ! otool -l "$f" | grep -A2 LC_RPATH | grep -q '@loader_path'; then
    echo "[ERROR] $(basename "$f") has no rpath @loader_path"
    exit 1
  fi
done
lipo -archs "$stage/libqwen.dylib"
# the loader resolves every library from beside libqwen, from a folder the build never saw
python3 -c "import ctypes, sys; ctypes.CDLL(sys.argv[1]); print('[OK] libqwen.dylib loads')" "$stage/libqwen.dylib"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
(cd "$stage" && tar -czf "$out/qwen-macos-arm64.tar.gz" *.dylib)
(cd "$out" && shasum -a 256 qwen-macos-arm64.tar.gz && stat -f '%z bytes' qwen-macos-arm64.tar.gz)
tar -tzvf "$out/qwen-macos-arm64.tar.gz"
echo "[OK] $out/qwen-macos-arm64.tar.gz"
