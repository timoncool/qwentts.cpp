#!/bin/bash
# libqwen.so with its ggml libraries for Linux x86-64 (the Windows engine's counterpart), built in an Ubuntu 22.04
# container (glibc 2.35: runs there and on anything newer) from the committed HEAD. CUDA 13.3, machine code for
# sm 75/80/86/89/90/100/120 and no PTX, no NCCL, no native CPU flags. RUNPATH looks beside the library and in
# ../higgs-engine, where a studio keeps the CUDA runtime and cuBLAS.
#   scripts/build-engine-linux-docker.sh <output folder> [cache folder]
set -euo pipefail

if [ "${1:-}" = "--inside" ]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q >/dev/null
  apt-get install -y -q --no-install-recommends git ninja-build python3-pip ca-certificates build-essential >/dev/null
  pip3 install -q "cmake>=3.28" >/dev/null
  echo "[..] source $(git -c safe.directory=/src -C /src rev-parse --short HEAD)"
  rm -rf /cache/src && mkdir -p /cache/src
  git -c safe.directory=/src -C /src archive HEAD | tar -x -C /cache/src
  cd /cache/src
  # settings come from this script alone, not from a cache an earlier run left
  rm -rf /cache/build/CMakeCache.txt
  cmake -B /cache/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DQWEN_SHARED=ON -DBUILD_SHARED_LIBS=ON \
    -DGGML_CUDA=ON -DGGML_CUDA_NCCL=OFF -DGGML_NATIVE=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON \
    -DGGML_AVX512=OFF "-DCMAKE_CUDA_ARCHITECTURES=75-real;80-real;86-real;89-real;90-real;100-real;120-real" \
    '-DCMAKE_BUILD_RPATH=$ORIGIN;$ORIGIN/../higgs-engine' >/dev/null
  echo "[..] build"
  cmake --build /cache/build --target qwen -j "$(( $(nproc) * 3 / 4 ))" 2>&1 | tail -3
  mkdir -p /out/qwen
  find /cache/build -name 'libqwen.so*' -o -name 'libggml*.so*' | while read -r f; do cp -L "$f" /out/qwen/; done
  for f in /out/qwen/*.so*; do echo "$(basename "$f"): zmm $(objdump -d --no-show-raw-insn "$f" | grep -c '%zmm' || true)"; done
  readelf -d /out/qwen/libqwen.so | grep -E 'NEEDED|RUNPATH'
  sha256sum /out/qwen/*.so*
  echo "[OK] libqwen.so"
  exit 0
fi

out="${1:?output folder}"
cache="${2:-$HOME/qwentts-linux2204-cache}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$out" "$cache"
cp "$repo/scripts/build-engine-linux-docker.sh" "$out/.build-engine-linux-docker.sh"
docker run --rm -v "$repo:/src:ro" -v "$(cd "$out" && pwd):/out" -v "$cache:/cache" nvidia/cuda:13.3.1-devel-ubuntu22.04 bash /out/.build-engine-linux-docker.sh --inside
