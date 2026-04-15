#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
  bash \
  build-essential \
  ca-certificates \
  cmake \
  curl \
  git \
  git-lfs \
  gnupg2 \
  jq \
  libdbus-1-dev \
  libssl-dev \
  ninja-build \
  pkg-config \
  python3 \
  python3-dev \
  python3-pip \
  python3-venv \
  unzip \
  xz-utils \
  zip

curl -fsSL -o /tmp/cuda-keyring.deb \
  https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb
dpkg -i /tmp/cuda-keyring.deb
rm -f /tmp/cuda-keyring.deb

apt-get update
apt-get install -y --no-install-recommends cuda-toolkit-13-2

git lfs install --system || true

apt-get clean
rm -rf /var/lib/apt/lists/*

if [[ -d /usr/local/cuda-13.2 && ! -e /usr/local/cuda ]]; then
  ln -s /usr/local/cuda-13.2 /usr/local/cuda
fi

export CUDA_HOME=/usr/local/cuda
export PATH="${CUDA_HOME}/bin:${PATH}"

"${CUDA_HOME}/bin/nvcc" --version
