#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is required}"
: "${NODE_MAJOR:?NODE_MAJOR is required}"
: "${JUST_VERSION:?JUST_VERSION is required}"
: "${SCCACHE_VERSION:?SCCACHE_VERSION is required}"
: "${OPENAI_NPM_VERSION:?OPENAI_NPM_VERSION is required}"

# shellcheck source=scripts/install-tools-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-tools-common.sh"

case "$TARGETARCH" in
  amd64) rust_arch=x86_64 ;;
  arm64) rust_arch=aarch64 ;;
  *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;;
esac

validate_tool_pins() {
  validate_exact_versions PNPM_VERSION RUST_VERSION JUST_VERSION SCCACHE_VERSION OPENAI_NPM_VERSION
}

wire_node_from_base() {
  install_node_tools
  # Full images also provide the pinned CLI smoke dependency.
  npm install --global "openai@${OPENAI_NPM_VERSION}"
}

install_rust() {
  local installed_rust compiler version
  # runuser (util-linux) switches user without consulting sudoers; the
  # actions/runner base image's /etc/sudoers omits the standard
  # `root ALL=(...)` entry and the @includedir /etc/sudoers.d directive,
  # so `sudo -u runner` from a root RUN context would fail.
  # Expand the positional version argument only inside the runner shell.
  # shellcheck disable=SC2016
  runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    bash -o pipefail -c 'curl --proto "=https" --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain "$1"' \
      rustup-install "$RUST_VERSION"
  runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/rustup component add --toolchain "$RUST_VERSION" clippy rustfmt
  runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/rustup target add --toolchain "$RUST_VERSION" aarch64-linux-android
  installed_rust="$(runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/rustc --version)" || return
  read -r compiler version _ <<< "$installed_rust"
  [[ "$compiler" == rustc ]] || { echo "unexpected Rust version output: $installed_rust" >&2; return 1; }
  verify_installed_version rustc "$RUST_VERSION" "$version"
}

install_sccache() {
  local archive="sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl.tar.gz"
  local base="https://github.com/mozilla/sccache/releases/download/v${SCCACHE_VERSION}"
  local archive_path="${download_cache}/${archive}"
  local checksum_path="${archive_path}.sha256"
  download_verified "${base}/${archive}" "$archive_path" "${base}/${archive}.sha256" "$checksum_path" ""
  tar -xzf "$archive_path"
  install -m 0755 "sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl/sccache" /usr/local/bin/sccache
  rm -rf "sccache-v${SCCACHE_VERSION}-${rust_arch}-unknown-linux-musl"
}

cd /tmp
validate_tool_pins
wire_node_from_base
install_rust
install_just
install_sccache

node --version
pnpm --version
rustc --version
just --version
sccache --version
