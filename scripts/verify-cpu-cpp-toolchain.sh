#!/usr/bin/env bash
set -euo pipefail

llvm_prefix=/usr/lib/llvm-19
for tool in clang clang++ clang-format clang-tidy FileCheck llvm-config; do
  selected="$(command -v "$tool")" || { echo "missing CPU LLVM tool: $tool" >&2; exit 1; }
  [[ "$selected" == "$llvm_prefix/bin/$tool" ]] || {
    echo "CPU LLVM tool does not resolve to the LLVM 19 toolchain: $tool" >&2
    exit 1
  }
  version="$("$tool" --version)"
  if [[ "$tool" == llvm-config ]]; then
    [[ "$version" == 19.* ]] || { echo "wrong LLVM development version" >&2; exit 1; }
  else
    [[ "$version" =~ version[[:space:]]19\. ]] || {
      echo "wrong CPU LLVM major: $tool" >&2
      exit 1
    }
  fi
done

for development_file in \
  lib/cmake/llvm/LLVMConfig.cmake \
  lib/cmake/clang/ClangConfig.cmake \
  include/clang/AST/ASTContext.h \
  include/clang-tidy/ClangTidy.h; do
  test -s "$llvm_prefix/$development_file" || {
    echo "missing CPU clang-tidy plugin development input: $development_file" >&2
    exit 1
  }
done

probe_directory="$(mktemp -d)"
trap 'rm -rf "$probe_directory"' EXIT
cat > "$probe_directory/expected.cpp" <<'CPP'
#include <expected>

int main() {
    std::expected<int, int> value{20};
    auto result = value.and_then([](int input) {
        return std::expected<int, int>{input + 1};
    }).transform([](int input) { return input * 2; });
    std::expected<int, int> failure = std::unexpected(7);
    auto recovered = failure.or_else([](int error) {
        return std::expected<int, int>{error};
    });
    auto changed = failure.transform_error([](int error) { return error + 1; });
    std::expected<void, int> empty{};
    auto completed = empty.and_then([] { return std::expected<int, int>{1}; });
    return result && *result == 42 && recovered && *recovered == 7 &&
        !changed && changed.error() == 8 && completed && *completed == 1 ? 0 : 1;
}
CPP
clang++ -std=c++23 -Wall -Wextra -Werror -fsanitize=address,undefined \
  "$probe_directory/expected.cpp" -o "$probe_directory/expected"
"$probe_directory/expected"

cat > "$probe_directory/fuzzer.cpp" <<'CPP'
#include <cstddef>
#include <cstdint>
extern "C" int LLVMFuzzerTestOneInput(const std::uint8_t*, std::size_t) { return 0; }
CPP
clang++ -std=c++23 -fsanitize=fuzzer,address,undefined \
  "$probe_directory/fuzzer.cpp" -o "$probe_directory/fuzzer"
"$probe_directory/fuzzer" -runs=1
