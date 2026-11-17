#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
installer="$repository_root/scripts/install-llvm22-libtooling.sh"
verifier="$repository_root/scripts/verify-runner-image.sh"

bash -n "$installer"
for package in clang-22 libclang-22-dev libclang-cpp22-dev lld-22 llvm-22-dev; do
  grep -Fq "$package" "$installer"
done
grep -Fq 'llvm-toolchain-noble-22' "$installer"
grep -Fq 'verify_llvm22_libtooling' "$verifier"
grep -Fq 'ClangConfig.cmake' "$verifier"
grep -Fq 'target_link_libraries(llvm22-libtooling-probe PRIVATE clang-cpp LLVM)' "$verifier"
