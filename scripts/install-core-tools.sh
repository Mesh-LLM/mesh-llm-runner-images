#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is required}"
: "${NODE_MAJOR:?NODE_MAJOR is required}"
: "${JUST_VERSION:?JUST_VERSION is required}"
: "${SCCACHE_VERSION:?SCCACHE_VERSION is required}"

case "$TARGETARCH" in
  amd64) rust_arch=x86_64 ;;
  arm64) rust_arch=aarch64 ;;
  *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac

install_node() {
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg
  printf 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' "$NODE_MAJOR" \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update
  apt-get install -y --no-install-recommends nodejs
  npm install --global "pnpm@10"
  apt-get clean
  rm -rf /var/lib/apt/lists/*
}

install_rust() {
  sudo -u runner env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    bash -c 'curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable'
  sudo -u runner env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/rustup component add clippy rustfmt
  sudo -u runner env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/rustup target add aarch64-linux-android
}

install_just() {
  local archive="just-${JUST_VERSION}-${rust_arch}-unknown-linux-musl.tar.gz"
  local base="https://github.com/casey/just/releases/download/${JUST_VERSION}"
  curl -fsSLO "${base}/${archive}"
  curl -fsSLo SHA256SUMS "${base}/SHA256SUMS"
  grep " ${archive}$" SHA256SUMS | sha256sum -c -
  tar -xzf "$archive" just
  install -m 0755 just /usr/local/bin/just
  rm -f "$archive" SHA256SUMS just
}

install_sccache() {
  local archive="sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl.tar.gz"
  local base="https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}"
  curl -fsSLO "${base}/${archive}"
  curl -fsSLO "${base}/${archive}.sha256"
  printf '%s  %s\n' "$(cat "${archive}.sha256")" "$archive" | sha256sum -c -
  tar -xzf "$archive"
  install -m 0755 "sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl/sccache" /usr/local/bin/sccache
  rm -rf "$archive" "${archive}.sha256" "sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl"
}

cd /tmp
install_node
install_rust
install_just
install_sccache

node --version
pnpm --version
rustc --version
just --version
sccache --version
