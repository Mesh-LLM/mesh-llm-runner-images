#!/usr/bin/env bash
set -euo pipefail

manifest_root="${1:-/opt/mesh-llm/manifests}"
test -f "$manifest_root/dependency-index.json"
mkdir -p /home/runner/.npm /home/runner/.local/share/pnpm/store
chown -R runner:docker /home/runner/.npm /home/runner/.local/share/pnpm

if [[ -f "$manifest_root/Cargo.toml" && -f "$manifest_root/Cargo.lock" ]]; then
  runuser -u runner -- env HOME=/home/runner CARGO_HOME=/home/runner/.cargo RUSTUP_HOME=/home/runner/.rustup \
    /home/runner/.cargo/bin/cargo fetch --locked --manifest-path "$manifest_root/Cargo.toml"
fi

python_lock=/etc/mesh-runner-python-requirements.lock
[[ -s "$python_lock" ]] || {
  echo "missing Python runtime lock: $python_lock" >&2
  exit 1
}
python3 -m venv /opt/mesh-llm/venv
# Install only the reviewed dependency closure; never resolve floating source
# requirements while rebuilding the image.
/opt/mesh-llm/venv/bin/pip install --disable-pip-version-check --no-deps \
  -r "$python_lock"
/opt/mesh-llm/venv/bin/pip check
if [[ -f "$manifest_root/ci/requirements-ci-python.txt" ]]; then
  /usr/local/bin/verify-python-requirements /opt/mesh-llm/venv/bin/pip \
    "$manifest_root/ci/requirements-ci-python.txt"
fi

if [[ -f "$manifest_root/crates/mesh-llm-ui/pnpm-lock.yaml" ]]; then
  runuser -u runner -- env HOME=/home/runner PNPM_HOME=/home/runner/.local/share/pnpm \
    npm_config_store_dir=/home/runner/.local/share/pnpm/store \
    pnpm --dir "$manifest_root/crates/mesh-llm-ui" fetch --frozen-lockfile
  rm -rf "$manifest_root/crates/mesh-llm-ui/node_modules"
fi

if [[ -f "$manifest_root/website/package-lock.json" && -f "$manifest_root/website/package.json" ]]; then
  runuser -u runner -- env HOME=/home/runner NPM_CONFIG_CACHE=/home/runner/.npm \
    npm --prefix "$manifest_root/website" ci --ignore-scripts --no-audit --no-fund
  rm -rf "$manifest_root/website/node_modules"
fi

chown -R runner:docker /opt/mesh-llm /home/runner/.cargo /home/runner/.npm /home/runner/.local
