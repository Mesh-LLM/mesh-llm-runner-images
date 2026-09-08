#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=scripts/install-tools-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/install-tools-common.sh"

install_ui_tools() {
  local node_version
  [[ "${TARGETARCH:-}" == amd64 ]] || { echo "lean UI images require amd64" >&2; return 1; }
  [[ "${NODE_MAJOR:-}" == 24 ]] || { echo "lean UI images require Node 24" >&2; return 1; }
  validate_exact_versions PNPM_VERSION JUST_VERSION
  install_node_tools
  node_version="$(node --version)"
  [[ "$node_version" == v24.* ]] || { echo "expected Node 24, found '$node_version'" >&2; return 1; }
  install_just
  printf '%s\n' "$node_version"
  pnpm --version
  just --version
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  cd /tmp
  install_ui_tools
fi
