#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is required}"
: "${RUNNER_VERSION:?RUNNER_VERSION is required}"

case "$TARGETARCH" in
  amd64)
    runner_arch=x64
    expected_sha="${RUNNER_SHA256_AMD64:?RUNNER_SHA256_AMD64 is required}"
    ;;
  arm64)
    runner_arch=arm64
    expected_sha="${RUNNER_SHA256_ARM64:?RUNNER_SHA256_ARM64 is required}"
    ;;
  *) echo "unsupported runner architecture: $TARGETARCH" >&2; exit 1 ;;
esac

archive="actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz"
url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${archive}"
download_cache="${DOWNLOAD_CACHE_DIR:-/var/cache/mesh-downloads}"
archive_path="${download_cache}/${archive}"

mkdir -p /home/runner "$download_cache"
test -s "$archive_path" || curl -fsSL --retry 3 "$url" -o "$archive_path"
printf '%s  %s\n' "$expected_sha" "$archive_path" | sha256sum -c -
tar -xzf "$archive_path" -C /home/runner --owner=runner --group=docker

test -x /home/runner/run.sh
