#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

export DOWNLOAD_CACHE_DIR="$temporary/cache"
export JUST_VERSION=test
export NODE_MAJOR=24
export SCCACHE_VERSION=test
export TARGETARCH=amd64

# Load only the cache helper; the remainder installs the full runner toolchain.
# shellcheck disable=SC1090
source <(awk '/^case "\$TARGETARCH" in$/ { exit } { print }' \
  "$repo_root/scripts/install-core-tools.sh")

archive="$temporary/cache/tool.tar.gz"
checksum="$archive.sha256"
printf 'partial archive' > "$archive"
printf 'invalid\n' > "$checksum"

curl() {
  return 22
}

if download_verified \
    https://example.invalid/tool.tar.gz "$archive" \
    https://example.invalid/tool.tar.gz.sha256 "$checksum" ""; then
  echo "malformed cached checksum was accepted" >&2
  exit 1
fi

test ! -e "$archive"
test ! -e "$checksum"
test -z "$(find "$temporary/cache" -type f -name '*.tmp.*' -print -quit)"

echo "download cache checksum validation passed"
