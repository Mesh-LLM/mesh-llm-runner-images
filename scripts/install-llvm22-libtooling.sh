#!/usr/bin/env bash
set -euo pipefail

keyring=/etc/apt/keyrings/apt.llvm.org.gpg
source_list=/etc/apt/sources.list.d/apt.llvm.org.list
staged_key="$(mktemp)"
cleanup() {
  rm -f "$staged_key"
}
trap cleanup EXIT

install -d -m 0755 /etc/apt/keyrings
curl -fsSL --retry 3 https://apt.llvm.org/llvm-snapshot.gpg.key -o "$staged_key"
gpg --batch --yes --dearmor --output "$keyring" "$staged_key"
chmod 0644 "$keyring"
printf '%s\n' \
  'deb [signed-by=/etc/apt/keyrings/apt.llvm.org.gpg] https://apt.llvm.org/noble/ llvm-toolchain-noble-22 main' \
  > "$source_list"

apt-get update
apt-get install -y --no-install-recommends \
  clang-22 \
  libclang-22-dev \
  libclang-cpp22-dev \
  lld-22 \
  llvm-22-dev

prefix=/usr/lib/llvm-22
"$prefix/bin/clang" --version | grep -F 'clang version 22.'
test -r "$prefix/lib/cmake/llvm/LLVMConfig.cmake"
test -r "$prefix/lib/cmake/clang/ClangConfig.cmake"
