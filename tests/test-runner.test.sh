#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
mkdir -p "$temporary_directory/scripts" "$temporary_directory/tests"
cp "$repository_root/scripts/test.sh" "$temporary_directory/scripts/"
export TEST_DISCOVERY_LOG="$temporary_directory/executed"
cat > "$temporary_directory/tests/first.test.sh" <<'TEST'
echo first >> "$TEST_DISCOVERY_LOG"
TEST
cat > "$temporary_directory/tests/second.test.sh" <<'TEST'
echo second >> "$TEST_DISCOVERY_LOG"
TEST
bash "$temporary_directory/scripts/test.sh" > "$temporary_directory/output"
[[ "$(cat "$TEST_DISCOVERY_LOG")" == $'first\nsecond' ]]
grep -Fq 'All 2 runner image test suites passed' "$temporary_directory/output"

printf 'exit 7\n' > "$temporary_directory/tests/first.test.sh"
: > "$TEST_DISCOVERY_LOG"
if bash "$temporary_directory/scripts/test.sh" > "$temporary_directory/output" 2>&1; then
  echo "test runner ignored a failing suite" >&2
  exit 1
fi
test ! -s "$TEST_DISCOVERY_LOG"
if grep -Fq 'suites passed' "$temporary_directory/output"; then
  echo "test runner falsely reported success" >&2
  exit 1
fi
echo "test discovery and failure propagation passed"
