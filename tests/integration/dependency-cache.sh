#!/usr/bin/env bash
set -euo pipefail

# Opt-in Docker integration test; excluded from scripts/test.sh discovery.
# Use a locally built full public or self-hosted image, not the toolchain stage:
#   bash tests/integration/dependency-cache.sh IMAGE
# Each user gets a fresh container, with no mounted host cache or network.
if [[ $# -ne 1 || -z "$1" || "$1" == -* ]]; then
  echo "usage: dependency-cache.sh LOCAL_IMAGE" >&2
  exit 2
fi
image="$1"
command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker image inspect "$image" >/dev/null

for runtime_user in root runner; do
  echo "Checking offline dependency stores as $runtime_user with HOME=/github/home"
  docker run --rm --interactive --pull=never --network none \
    --user "$runtime_user" --env HOME=/github/home --env CI=true \
    --entrypoint /bin/bash "$image" -s -- "$runtime_user" <<'CONTAINER'
set -euo pipefail
expected_user="$1"
[[ "$(id -un)" == "$expected_user" ]]
[[ "$HOME" == /github/home ]]
test -d "$HOME"
test -w "$HOME"

manifest_root=/opt/mesh-llm/manifests
test -s "$manifest_root/dependency-index.json"
for manifest in website/package.json website/package-lock.json \
  crates/mesh-llm-ui/package.json crates/mesh-llm-ui/pnpm-lock.yaml; do
  test -s "$manifest_root/$manifest"
done
retained_modules="$(find "$manifest_root" -name node_modules -print -quit)"
if [[ -n "$retained_modules" ]]; then
  echo "image retained installed dependencies: $retained_modules" >&2
  exit 1
fi

# Check linked stores before expensive installs. Writable parent directories
# matter for Cargo lock/index updates and future pip dependency reconciliation.
[[ "${CARGO_HOME:-}" == /home/runner/.cargo ]]
[[ "${VIRTUAL_ENV:-}" == /opt/mesh-llm/venv ]]
venv_site="$(python -c 'import os, sys, sysconfig; assert sys.prefix == os.environ["VIRTUAL_ENV"]; print(sysconfig.get_path("purelib"))')"
for writable_directory in "$CARGO_HOME/registry" "$CARGO_HOME/git" \
  "$VIRTUAL_ENV" "$VIRTUAL_ENV/bin" "$venv_site"; do
  test -d "$writable_directory"
  write_probe="$(mktemp "$writable_directory/.mesh-write-probe.XXXXXX")"
  rm -f "$write_probe"
done
echo "Cargo registry/git and Python venv write checks passed as $expected_user"

consumption_root="$(mktemp -d /tmp/mesh-dependency-cache.XXXXXX)"
trap 'rm -rf "$consumption_root"' EXIT
# Preserve root and project package-manager configuration, including .npmrc
# and pnpm-workspace.yaml, without modifying the baked manifest snapshot.
cp -R "$manifest_root/." "$consumption_root/"

cd "$consumption_root/website"
npm_cache="$(npm config get cache)"
[[ "$npm_cache" == /home/runner/.npm ]] || {
  echo "npm resolved the wrong cache with Actions HOME: $npm_cache" >&2
  exit 1
}
test -d "$npm_cache/_cacache"
npm_probe="$(mktemp "$npm_cache/.mesh-write-probe.XXXXXX")"
rm -f "$npm_probe"

cd "$consumption_root/crates/mesh-llm-ui"
pnpm_store="$(pnpm store path)"
case "$pnpm_store" in
  /home/runner/.local/share/pnpm/store|/home/runner/.local/share/pnpm/store/*) ;;
  *) echo "pnpm resolved the wrong store with Actions HOME: $pnpm_store" >&2; exit 1 ;;
esac
test -d "$pnpm_store"
pnpm_probe="$(mktemp "$pnpm_store/.mesh-write-probe.XXXXXX")"
rm -f "$pnpm_probe"

cd "$consumption_root/website"
started=$SECONDS
npm ci --offline --ignore-scripts --no-audit --no-fund
test -d node_modules
echo "npm offline install passed as $expected_user in $((SECONDS - started))s"

cd "$consumption_root/crates/mesh-llm-ui"
started=$SECONDS
pnpm install --offline --frozen-lockfile --ignore-scripts
test -d node_modules
test -s node_modules/.modules.yaml
echo "pnpm offline install passed as $expected_user in $((SECONDS - started))s"
CONTAINER
done

echo "Offline dependency cache integration passed for root and runner"
