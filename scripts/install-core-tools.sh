#!/usr/bin/env bash
set -euo pipefail

: "${TARGETARCH:?TARGETARCH is required}"
: "${NODE_MAJOR:?NODE_MAJOR is required}"
: "${JUST_VERSION:?JUST_VERSION is required}"
: "${SCCACHE_VERSION:?SCCACHE_VERSION is required}"

download_cache="${DOWNLOAD_CACHE_DIR:-/var/cache/mesh-downloads}"
mkdir -p "$download_cache"

download_verified() {
  local archive_url="$1"
  local archive_path="$2"
  local checksum_url="$3"
  local checksum_path="$4"
  local checksum_name="$5"
  local archive_tmp checksum_tmp expected_sha

  if [[ -s "$archive_path" && -s "$checksum_path" ]]; then
    if [[ -n "$checksum_name" ]]; then
      expected_sha="$(awk -v name="$checksum_name" '$2 == name { print $1; exit }' "$checksum_path")"
    else
      expected_sha="$(awk 'NR == 1 { print $1 }' "$checksum_path")"
    fi
    if [[ "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]] \
        && printf '%s  %s\n' "$expected_sha" "$archive_path" | sha256sum -c - >/dev/null 2>&1; then
      return 0
    fi
  fi

  rm -f "$archive_path" "$checksum_path"
  archive_tmp="$(mktemp "${archive_path}.tmp.XXXXXX")"
  checksum_tmp="$(mktemp "${checksum_path}.tmp.XXXXXX")"
  if ! curl -fsSL --retry 3 "$archive_url" -o "$archive_tmp" \
      || ! curl -fsSL --retry 3 "$checksum_url" -o "$checksum_tmp"; then
    rm -f "$archive_tmp" "$checksum_tmp"
    return 1
  fi

  if [[ -n "$checksum_name" ]]; then
    expected_sha="$(awk -v name="$checksum_name" '$2 == name { print $1; exit }' "$checksum_tmp")"
  else
    expected_sha="$(awk 'NR == 1 { print $1 }' "$checksum_tmp")"
  fi
  if [[ ! "$expected_sha" =~ ^[[:xdigit:]]{64}$ ]] \
      || ! printf '%s  %s\n' "$expected_sha" "$archive_tmp" | sha256sum -c -; then
    rm -f "$archive_tmp" "$checksum_tmp"
    return 1
  fi

  mv -f "$archive_tmp" "$archive_path"
  mv -f "$checksum_tmp" "$checksum_path"
}

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
  download_verified "${base}/${archive}" "$archive_path" "${base}/SHA256SUMS" "$checksums" "$archive"
  tar -xzf "$archive_path" just
  install -m 0755 just /usr/local/bin/just
  rm -f just
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
wire_node_from_base
install_rust
install_just
install_sccache

node --version
pnpm --version
rustc --version
just --version
sccache --version
