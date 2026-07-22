#!/usr/bin/env bash
set -euo pipefail

manifest_root="${1:-/opt/mesh-llm/manifests}"
test -f "$manifest_root/manifest-index.json"

if [[ -f "$manifest_root/Cargo.toml" && -f "$manifest_root/Cargo.lock" ]]; then
  sudo -u runner env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/cargo fetch --locked --manifest-path "$manifest_root/Cargo.toml"
fi

python3 -m venv /opt/mesh-llm/venv
if [[ -f "$manifest_root/ci/requirements-ci-python.txt" ]]; then
  /opt/mesh-llm/venv/bin/pip install --disable-pip-version-check --no-cache-dir \
    -r "$manifest_root/ci/requirements-ci-python.txt"
fi

if [[ -f "$manifest_root/crates/mesh-llm-ui/pnpm-lock.yaml" ]]; then
  sudo -u runner env HOME=/home/runner PNPM_HOME=/home/runner/.local/share/pnpm \
    bash -c "cd '$manifest_root/crates/mesh-llm-ui' && pnpm fetch --frozen-lockfile"
fi

if [[ -f "$manifest_root/website/package-lock.json" && -f "$manifest_root/website/package.json" ]]; then
  sudo -u runner env HOME=/home/runner npm_config_cache=/home/runner/.npm \
    bash -c "cd '$manifest_root/website' && npm ci --ignore-scripts --no-audit --no-fund"
fi

chown -R runner:docker /opt/mesh-llm /home/runner/.cargo /home/runner/.npm /home/runner/.local 2>/dev/null || true
