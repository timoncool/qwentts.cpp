#!/bin/bash
# libqwen.so with its ggml libraries for Linux x86-64 (the Windows engine's counterpart), built in an Ubuntu 22.04
# container (glibc 2.35: runs there and on anything newer) from the committed HEAD, no native CPU flags, no AVX-512,
# no NCCL, machine code only (no PTX).
#   cuda (default): CUDA 13.3, sm 75/80/86/89/90/100/120.
#   cuda12:         CUDA 12.9, sm 52/60/61/70/75/80/86/89/90/120a.
#   vulkan:         Vulkan and the CPU (LunarG Vulkan SDK; the system's Vulkan loader at run time).
#   cpu:            the CPU alone.
# RUNPATH looks beside the library and in ../higgs-engine, where a studio keeps the CUDA runtime and cuBLAS.
#   scripts/build-engine-linux-docker.sh <output folder> [cache folder] [cuda|cuda12|vulkan|cpu]
set -euo pipefail

VULKAN_SDK_VERSION="1.4.357.0"

if [ "${1:-}" = "--inside" ]; then
  backend="$2"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null
  apt-get install -y -q --no-install-recommends git ninja-build python3-pip ca-certificates build-essential curl xz-utils patchelf >/dev/null
  pip3 install -q "cmake>=3.28" >/dev/null
  flags=(-DGGML_CUDA=OFF -DGGML_VULKAN=OFF)
  case "$backend" in
    cuda) flags=(-DGGML_CUDA=ON -DGGML_CUDA_NCCL=OFF "-DCMAKE_CUDA_ARCHITECTURES=75-real;80-real;86-real;89-real;90-real;100-real;120-real") ;;
    cuda12) flags=(-DGGML_CUDA=ON -DGGML_CUDA_NCCL=OFF "-DCMAKE_CUDA_FLAGS=-Wno-deprecated-gpu-targets"
                   "-DCMAKE_CUDA_ARCHITECTURES=52-real;60-real;61-real;70-real;75-real;80-real;86-real;89-real;90-real;120a-real") ;;
    vulkan)
      sdk=/cache/vulkansdk-$VULKAN_SDK_VERSION
      if [ ! -x "$sdk/x86_64/bin/glslc" ]; then
        echo "[..] Vulkan SDK $VULKAN_SDK_VERSION"
        mkdir -p "$sdk"
        curl -fsSL "https://sdk.lunarg.com/sdk/download/$VULKAN_SDK_VERSION/linux/vulkansdk-linux-x86_64-$VULKAN_SDK_VERSION.tar.xz" | tar -xJ -C "$sdk" --strip-components=1
      fi
      export VULKAN_SDK="$sdk/x86_64" PATH="$sdk/x86_64/bin:$PATH"
      cp -P "$sdk"/x86_64/lib/VulkanLoader/lib/libvulkan.so* /usr/lib/x86_64-linux-gnu/
      flags=(-DGGML_CUDA=OFF -DGGML_VULKAN=ON -DVulkan_LIBRARY=/usr/lib/x86_64-linux-gnu/libvulkan.so) ;;
    cpu) ;;
    *) echo "[ERROR] backend $backend: cuda, cuda12, vulkan or cpu"; exit 1 ;;
  esac
  echo "[..] source $(git -c safe.directory='*' -C /src rev-parse --short HEAD), $backend"
  rm -rf /cache/src && mkdir -p /cache/src
  git -c safe.directory='*' -C /src archive HEAD | tar -x -C /cache/src
  git -c safe.directory='*' -C /src submodule status --recursive | while read -r _ path _; do
    git -c safe.directory='*' -C "/src/$path" archive HEAD | tar -x -C "/cache/src/$path"
  done
  cd /cache/src
  # settings come from this script alone, not from a cache an earlier run left
  rm -rf "/cache/build-$backend/CMakeCache.txt"
  cmake -B "/cache/build-$backend" -G Ninja -DCMAKE_BUILD_TYPE=Release -DQWEN_SHARED=ON -DBUILD_SHARED_LIBS=ON \
    -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON -DGGML_AVX512=OFF \
    '-DCMAKE_BUILD_RPATH=$ORIGIN;$ORIGIN/../higgs-engine' "${flags[@]}" >/dev/null
  echo "[..] build"
  cmake --build "/cache/build-$backend" --target qwen -j "$(( $(nproc) * 3 / 4 ))" 2>&1 | tail -3
  out="/out/$backend"
  rm -rf "$out" && mkdir -p "$out"
  find "/cache/build-$backend" -name 'libqwen.so*' -o -name 'libggml*.so*' | while read -r f; do cp -L "$f" "$out/"; done
  # the CUDA toolkit's folder of the build machine must not reach a user's machine
  for f in "$out"/*.so*; do patchelf --set-rpath '$ORIGIN:$ORIGIN/../higgs-engine' "$f"; done
  for f in "$out"/*.so*; do echo "$(basename "$f"): zmm $(objdump -d --no-show-raw-insn "$f" | grep -c '%zmm' || true)"; done
  readelf -d "$out/libqwen.so" | grep -E 'NEEDED|RUNPATH'
  sha256sum "$out"/*.so*
  echo "[OK] libqwen.so ($backend)"
  exit 0
fi

out="${1:?output folder}"
cache="${2:-$HOME/qwentts-linux2204-cache}"
backend="${3:-cuda}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out" "$cache"
cp "$repo/scripts/build-engine-linux-docker.sh" "$out/.build-engine-linux-docker.sh"
image=ubuntu:22.04
[ "$backend" = "cuda" ] && image=nvidia/cuda:13.3.1-devel-ubuntu22.04
[ "$backend" = "cuda12" ] && image=nvidia/cuda:12.9.1-devel-ubuntu22.04
docker run --rm --cpus "$(( $(nproc) * 2 / 3 ))" -v "$repo:/src:ro" -v "$(cd "$out" && pwd):/out" -v "$cache/$backend:/cache" "$image" bash /out/.build-engine-linux-docker.sh --inside "$backend"
