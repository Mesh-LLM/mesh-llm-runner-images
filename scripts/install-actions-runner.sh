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

mkdir -p /home/runner
curl -fsSL "$url" -o "/tmp/${archive}"
printf '%s  %s\n' "$expected_sha" "/tmp/${archive}" | sha256sum -c -
tar -xzf "/tmp/${archive}" -C /home/runner --owner=runner --group=docker
rm -f "/tmp/${archive}"

test -x /home/runner/run.sh
