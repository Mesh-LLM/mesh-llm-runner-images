#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT
# Resolve the pinned real pnpm before installing fixture command wrappers.
pnpm_pin="$(jq -r '.common.pnpm' "$repository_root/config/tool-pins.json")"
if ! command -v pnpm >/dev/null || [[ "$(pnpm --version)" != "$pnpm_pin" ]]; then
  echo "Skipping real dependency-warming layout regression: pnpm $pnpm_pin is unavailable"
  exit 0
fi
mkdir -p "$temporary_directory/package" "$temporary_directory/bin"
printf '{"name":"runner-store-fixture","version":"1.0.0"}\n' > "$temporary_directory/package/package.json"
tar -czf "$temporary_directory/package.tgz" -C "$temporary_directory" package
cat > "$temporary_directory/fixture-env.sh" <<'ENV'
chown() { :; }
runuser() { [[ "$1 $2 $3" == '-u runner --' ]]; shift 3; "$@"; }
python3() {
  [[ "$1 $2" == '-m venv' ]]
  mkdir -p "$3/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$3/bin/pip"
  chmod +x "$3/bin/pip"
}
ENV
cat > "$temporary_directory/bin/npm" <<'NPM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WARMER_CALL_LOG"
NPM
chmod +x "$temporary_directory/bin/npm"
for layout in legacy relocated; do
  if [[ "$layout" == legacy ]]; then ui=crates/mesh-llm-ui; website=website;
  else ui=mesh/crates/mesh-llm-ui; website=mesh/website; fi
  for kind in full lean; do
    case_root="$temporary_directory/$layout-$kind"
    runner="$case_root/runner"
    manifests="$case_root/opt/manifests"
    mkdir -p "$manifests/$ui" "$manifests/$website" "$case_root/scripts" "$case_root/etc"
    printf '{"schema":1,"files":[]}\n' > "$manifests/dependency-index.json"
    printf '{"name":"warming-fixture","private":true,"dependencies":{"runner-store-fixture":"file:%s"}}\n' \
      "$temporary_directory/package.tgz" > "$manifests/$ui/package.json"
    pnpm --dir "$manifests/$ui" install --lockfile-only --offline --ignore-scripts \
      --store-dir "$case_root/lock-preparation-store" > "$case_root/prepare.log" 2>&1
    printf '{}\n' > "$manifests/$website/package.json"
    printf '{}\n' > "$manifests/$website/package-lock.json"
    printf 'fixture==1.0.0\n' > "$case_root/etc/python.lock"
    if [[ "$kind" == full ]]; then script=warm-dependencies.sh; onnx_install="";
    else script=warm-ui-dependencies.sh; onnx_install=skip; fi
    source="$(cat "$repository_root/scripts/$script")"
    source="${source//\/home\/runner/$runner}"
    source="${source//\/opt\/mesh-llm/$case_root/opt}"
    source="${source//\/etc\/mesh-runner-python-requirements.lock/$case_root/etc/python.lock}"
    printf '%s\n' "$source" > "$case_root/scripts/warm.sh"
    cp "$repository_root/scripts/source-component-path.sh" "$case_root/scripts/"
    env BASH_ENV="$temporary_directory/fixture-env.sh" PATH="$temporary_directory/bin:$PATH" \
      WARMER_CALL_LOG="$case_root/npm.log" ONNXRUNTIME_NODE_INSTALL="$onnx_install" \
      bash "$case_root/scripts/warm.sh" "$manifests" > "$case_root/warm.log" 2>&1
    store="$(npm_config_store_dir="$runner/.local/share/pnpm/store" pnpm store path --silent)"
    [[ "$store" == "$runner/.local/share/pnpm/store/v10" && -d "$store" ]]
    [[ -n "$(find "$store" -type f -print -quit)" ]]
    test ! -d "$manifests/$ui/node_modules"
    if [[ "$kind" == full ]]; then grep -Fq -- "--prefix $manifests/$website ci" "$case_root/npm.log"; fi
  done
done
echo 'Legacy and relocated full/lean warmers populated real pinned pnpm stores'
