#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
prefix="$temporary_directory/llvm-19"
mkdir -p "$prefix/bin" "$prefix/lib/cmake/llvm" "$prefix/lib/cmake/clang" \
  "$prefix/include/clang/AST" "$prefix/include/clang-tidy"
for file in lib/cmake/llvm/LLVMConfig.cmake lib/cmake/clang/ClangConfig.cmake \
  include/clang/AST/ASTContext.h include/clang-tidy/ClangTidy.h; do
  printf 'fixture\n' > "$prefix/$file"
done
source="$(cat "$repository_root/scripts/verify-cpu-cpp-toolchain.sh")"
printf '%s\n' "${source//\/usr\/lib\/llvm-19/$prefix}" > "$temporary_directory/verify.sh"
cat > "$prefix/bin/tool" <<'TOOL'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --version ]]; then
  if [[ "${0##*/}" == llvm-config ]]; then
    printf '%s.1.1\n' "${FIXTURE_LLVM_MAJOR:-19}"
  else
    printf 'LLVM version %s.1.1\n' "${FIXTURE_LLVM_MAJOR:-19}"
  fi
  exit 0
fi
if [[ "${FIXTURE_COMPILE_FAIL:-false}" == true ]]; then exit 9; fi
output=""
while (($# > 0)); do
  if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
done
test -n "$output"
printf '#!/usr/bin/env bash\nexit %s\n' "${FIXTURE_PROBE_EXIT:-0}" > "$output"
chmod +x "$output"
TOOL
chmod +x "$prefix/bin/tool"
for tool in clang clang++ clang-format clang-tidy FileCheck llvm-config; do
  ln -s tool "$prefix/bin/$tool"
done
export PATH="$prefix/bin:$PATH"
expect_failure() {
  if "$@" > "$temporary_directory/failure" 2>&1; then
    echo "expected CPU toolchain verifier to reject fixture: $*" >&2
    exit 1
  fi
}
bash "$temporary_directory/verify.sh"
expect_failure env FIXTURE_LLVM_MAJOR=18 bash "$temporary_directory/verify.sh"
expect_failure env FIXTURE_COMPILE_FAIL=true bash "$temporary_directory/verify.sh"
expect_failure env FIXTURE_PROBE_EXIT=7 bash "$temporary_directory/verify.sh"
rm "$prefix/include/clang-tidy/ClangTidy.h"
expect_failure bash "$temporary_directory/verify.sh"
printf 'fixture\n' > "$prefix/include/clang-tidy/ClangTidy.h"
rm "$prefix/bin/FileCheck"
expect_failure bash "$temporary_directory/verify.sh"

packages="$(bash "$repository_root/scripts/profile-packages.sh" "$repository_root/profiles/backends/cpu.yml")"
for package in clang-19 clang-format-19 clang-tidy-19 g++-14 libclang-19-dev \
  libclang-rt-19-dev llvm-19-dev llvm-19-tools; do
  grep -qx "$package" <<< "$packages"
done
echo 'CPU C++23 tooling admission and rejection checks passed'
