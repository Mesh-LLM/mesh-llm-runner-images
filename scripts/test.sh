#!/usr/bin/env bash
set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  echo "runner image tests require Bash 4 or newer" >&2
  exit 1
fi
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Keep subprocesses on the same Bash, including on macOS with Homebrew Bash.
PATH="$(dirname "$BASH"):$PATH"
export PATH
shopt -s nullglob
suites=("$repository_root"/tests/*.test.sh)
if (( ${#suites[@]} == 0 )); then
  echo "no runner image test suites found" >&2
  exit 1
fi
for suite in "${suites[@]}"; do
  echo "Running $(basename "$suite")"
  "$BASH" "$suite"
done
echo "All ${#suites[@]} runner image test suites passed"
