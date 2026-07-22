#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is required}"
: "${INSTALL_CUDA:=1}"
: "${CUDA_SERIES:=12-9}"

if [[ "$INSTALL_CUDA" != "1" || "$TARGETARCH" != "amd64" ]]; then
  echo "Skipping CUDA toolkit for TARGETARCH=${TARGETARCH} INSTALL_CUDA=${INSTALL_CUDA}"
  exit 0
fi

curl -fsSL -o /tmp/cuda-keyring.deb \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i /tmp/cuda-keyring.deb
rm -f /tmp/cuda-keyring.deb

apt-get update
# MeshLLM's llama.cpp build needs the CUDA compiler, runtime headers, and
# cuBLAS. Avoid the cuda-toolkit meta-package: it also installs profilers,
# GUI tools, Java, documentation, and unrelated math libraries, adding several
# gigabytes to every ephemeral runner pull.
apt-get install -y --no-install-recommends \
  "cuda-compiler-${CUDA_SERIES}" \
  "cuda-cudart-dev-${CUDA_SERIES}" \
  "libcublas-dev-${CUDA_SERIES}"
apt-get clean
rm -rf /var/lib/apt/lists/*

if [[ -d "/usr/local/cuda-${CUDA_SERIES//-/.}" && ! -e /usr/local/cuda ]]; then
  ln -s "/usr/local/cuda-${CUDA_SERIES//-/.}" /usr/local/cuda
fi

/usr/local/cuda/bin/nvcc --version
test -f /usr/local/cuda/include/cublas_v2.h
find /usr/local/cuda/targets/x86_64-linux/lib -name 'libcublas.so*' -print -quit | grep -q .
