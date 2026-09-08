#!/usr/bin/env bash
set -euo pipefail

manifest_root="${1:-/opt/mesh-llm/manifests}"
test -s "$manifest_root/dependency-index.json"
test -s "$manifest_root/crates/mesh-llm-ui/package.json"
test -s "$manifest_root/crates/mesh-llm-ui/pnpm-lock.yaml"
[[ "${ONNXRUNTIME_NODE_INSTALL:-}" == skip ]] || {
  echo "lean UI warming requires ONNXRUNTIME_NODE_INSTALL=skip" >&2
  exit 1
}
mkdir -p /home/runner/.npm /home/runner/.local/share/pnpm/store
[[ -z "$(find /home/runner/.local/share/pnpm/store -mindepth 1 -maxdepth 1 -print -quit)" ]] || {
  echo "lean UI warming requires a fresh pnpm store" >&2
  exit 1
}
chown -R runner:docker /opt/mesh-llm/manifests /home/runner/.npm /home/runner/.local/share/pnpm
# Use a store built only by Dockerfile.ui. pnpm's side-effects key does not
# include ONNXRUNTIME_NODE_INSTALL, so a full-image store could restore CUDA
# libraries even while the lean installer skips their download.
runuser -u runner -- env HOME=/home/runner PNPM_HOME=/home/runner/.local/share/pnpm \
  npm_config_store_dir=/home/runner/.local/share/pnpm/store \
  NPM_CONFIG_CACHE=/home/runner/.npm ONNXRUNTIME_NODE_INSTALL=skip PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
  pnpm --dir "$manifest_root/crates/mesh-llm-ui" fetch --frozen-lockfile
rm -rf "$manifest_root/crates/mesh-llm-ui/node_modules"
chown -R runner:docker /opt/mesh-llm/manifests /home/runner/.npm /home/runner/.local/share/pnpm
