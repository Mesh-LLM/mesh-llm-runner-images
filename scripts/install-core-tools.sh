#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is required}"
: "${NODE_MAJOR:?NODE_MAJOR is required}"
: "${JUST_VERSION:?JUST_VERSION is required}"
: "${SCCACHE_VERSION:?SCCACHE_VERSION is required}"

download_cache="${DOWNLOAD_CACHE_DIR:-/var/cache/mesh-downloads}"
mkdir -p "$download_cache"

case "$TARGETARCH" in
  amd64) rust_arch=x86_64 ;;
  arm64) rust_arch=aarch64 ;;
  *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac

# The base image (ghcr.io/actions/actions-runner) ships node externals at
# /home/runner/externals/node<N>/bin/{node,npm,npx,corepack}. Per the
# Dockerfile's MUST-NOT contract, we do NOT `apt install nodejs` here;
# instead we symlink the NODE_MAJOR version into /usr/local/bin so the
# standard PATH works for both this script (pnpm via npm) and the
# verify-runner-image.sh `command -v node` assertion.
wire_node_from_base() {
  local externals_root="/home/runner/externals/node${NODE_MAJOR}/bin"
  test -x "${externals_root}/node" \
    || { echo "base image missing node${NODE_MAJOR} externals at ${externals_root}" >&2; exit 1; }
  for binary in node npm npx corepack; do
    ln -sf "${externals_root}/${binary}" "/usr/local/bin/${binary}"
  done
  npm install --global "pnpm@10"
}

install_rust() {
  # runuser (util-linux) switches user without consulting sudoers; the
  # actions/runner base image's /etc/sudoers omits the standard
  # `root ALL=(...)` entry and the @includedir /etc/sudoers.d directive,
  # so `sudo -u runner` from a root RUN context would fail.
  runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    bash -c 'curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable'
  runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/rustup component add clippy rustfmt
  runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/rustup target add aarch64-linux-android
}

install_just() {
  local archive="just-${JUST_VERSION}-${rust_arch}-unknown-linux-musl.tar.gz"
  local base="https://github.com/casey/just/releases/download/${JUST_VERSION}"
  local archive_path="${download_cache}/${archive}"
  local checksums="${download_cache}/just-${JUST_VERSION}-SHA256SUMS"
  test -s "$archive_path" || curl -fsSL --retry 3 "${base}/${archive}" -o "$archive_path"
  test -s "$checksums" || curl -fsSL --retry 3 "${base}/SHA256SUMS" -o "$checksums"
  grep " ${archive}$" "$checksums" | (cd "$download_cache" && sha256sum -c -)
  tar -xzf "$archive_path" just
  install -m 0755 just /usr/local/bin/just
  rm -f just
}

install_sccache() {
  local archive="sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl.tar.gz"
  local base="https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}"
  local archive_path="${download_cache}/${archive}"
  local checksum_path="${archive_path}.sha256"
  test -s "$archive_path" || curl -fsSL --retry 3 "${base}/${archive}" -o "$archive_path"
  test -s "$checksum_path" || curl -fsSL --retry 3 "${base}/${archive}.sha256" -o "$checksum_path"
  printf '%s  %s\n' "$(awk 'NR == 1 { print $1 }' "$checksum_path")" "$archive_path" | sha256sum -c -
  tar -xzf "$archive_path"
  install -m 0755 "sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl/sccache" /usr/local/bin/sccache
  rm -rf "sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl"
}

cd /tmp
wire_node_from_base
install_rust
install_just
install_sccache

node --version
pnpm --version
rustc --version
just --version
sccache --version
