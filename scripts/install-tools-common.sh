#!/usr/bin/env bash
# Shared pinned tool installers. Sourcing this file does not install anything.

download_cache="${DOWNLOAD_CACHE_DIR:-/var/cache/mesh-downloads}"

validate_exact_versions() {
  local version_name version
  for version_name in "$@"; do
    version="${!version_name:-}"
    [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || {
      echo "$version_name must be an exact MAJOR.MINOR.PATCH release version" >&2
      return 1
    }
  done
}

download_verified() {
  local archive_url="$1"
  local archive_path="$2"
  local checksum_url="$3"
  local checksum_path="$4"
  local checksum_name="$5"
  local archive_tmp checksum_tmp expected_sha
  mkdir -p "$download_cache"

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

verify_installed_version() {
  local tool="$1" expected="$2" actual="$3"
  [[ "$actual" == "$expected" ]] || {
    echo "expected $tool $expected, found '$actual'" >&2
    return 1
  }
}

# The base image (ghcr.io/actions/actions-runner) ships node externals at
# /home/runner/externals/node<N>/bin/{node,npm,npx,corepack}. Per the
# Dockerfile's MUST-NOT contract, we do NOT `apt install nodejs` here;
# instead we symlink the NODE_MAJOR version into /usr/local/bin so the
# standard PATH works for both this script (pnpm via npm) and the
# verify-runner-image.sh `command -v node` assertion.
install_node_tools() {
  local externals_root="/home/runner/externals/node${NODE_MAJOR}/bin"
  local installed_pnpm
  test -x "${externals_root}/node" \
    || { echo "base image missing node${NODE_MAJOR} externals at ${externals_root}" >&2; exit 1; }
  for binary in node npm npx corepack; do
    ln -sf "${externals_root}/${binary}" "/usr/local/bin/${binary}"
  done
  npm install --global "pnpm@${PNPM_VERSION}"
  installed_pnpm="$(pnpm --version)" || return
  verify_installed_version pnpm "$PNPM_VERSION" "$installed_pnpm" || return
}

install_just() {
  local tool_arch
  case "$TARGETARCH" in
    amd64) tool_arch=x86_64 ;;
    arm64) tool_arch=aarch64 ;;
    *) echo "unsupported architecture: $TARGETARCH" >&2; return 1 ;;
  esac
  local archive="just-${JUST_VERSION}-${tool_arch}-unknown-linux-musl.tar.gz"
  local base="https://github.com/casey/just/releases/download/${JUST_VERSION}"
  local archive_path="${download_cache}/${archive}"
  local checksums="${download_cache}/just-${JUST_VERSION}-SHA256SUMS"
  download_verified "${base}/${archive}" "$archive_path" "${base}/SHA256SUMS" "$checksums" "$archive"
  tar -xzf "$archive_path" just
  install -m 0755 just /usr/local/bin/just
  rm -f just
}

