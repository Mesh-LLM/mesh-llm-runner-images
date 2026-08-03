#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
measure_context="$repository_root/scripts/measure-docker-context.sh"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

mkdir -p \
  "$temporary_directory/profiles" \
  "$temporary_directory/scripts" \
  "$temporary_directory/build-context/manifests"
printf 'dockerfile' > "$temporary_directory/Dockerfile"
printf 'verify' > "$temporary_directory/Dockerfile.verify"
printf 'profile' > "$temporary_directory/profiles/profile.yml"
printf 'script' > "$temporary_directory/scripts/tool.sh"
printf 'manifest' > "$temporary_directory/build-context/manifests/index.json"
printf 'ignored' > "$temporary_directory/ignored.txt"

metrics="$(bash "$measure_context" "$temporary_directory")"
jq -e \
  --argjson expected_bytes "$((10 + 6 + 7 + 6 + 8))" \
  '.schema == 1 and .content_bytes == $expected_bytes and .file_count == 5' \
  <<< "$metrics" >/dev/null

mkdir -p \
  "$temporary_directory/incomplete/scripts" \
  "$temporary_directory/incomplete/build-context"
printf 'dockerfile' > "$temporary_directory/incomplete/Dockerfile"
printf 'verify' > "$temporary_directory/incomplete/Dockerfile.verify"
if bash "$measure_context" "$temporary_directory/incomplete" \
  >/dev/null 2>&1; then
  echo "expected missing context directory to fail" >&2
  exit 1
fi

echo "Docker context measurement contract passed"
