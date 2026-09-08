#!/usr/bin/env bash
set -euo pipefail

# Opt-in native AMD64 Docker qualification. DOCKER_HOST is honored; source is
# streamed over stdin, so the daemon never needs access to host bind mounts.
# MESH_SOURCE_REVISION may select another exact commit for future qualification.
if [[ $# -lt 2 || $# -gt 3 || "$1" == -* ]]; then
  echo "usage: ui-image.sh LOCAL_IMAGE MESH_LLM_CHECKOUT [LOG_DIRECTORY]" >&2
  exit 2
fi
image="$1"
source_repository="$(cd "$2" && pwd -P)"
source_revision="${MESH_SOURCE_REVISION-cd602d6cba0f505fd9e1b4a6b5d1ca261a0032a0}"
[[ "$source_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "MESH_SOURCE_REVISION must be a full lowercase git SHA" >&2
  exit 1
}
for required_command in docker git jq; do
  command -v "$required_command" >/dev/null || {
    echo "missing required command: $required_command" >&2; exit 1;
  }
done
git -C "$source_repository" cat-file -e "$source_revision^{commit}"
if [[ $# -eq 3 ]]; then
  mkdir -p "$3"
  evidence_directory="$(mktemp -d "$3/ui-image.XXXXXX")"
else
  evidence_directory="$(mktemp -d "${TMPDIR:-/tmp}/mesh-ui-image.XXXXXX")"
fi
evidence_directory="$(cd "$evidence_directory" && pwd -P)"
echo "Retaining UI qualification evidence in $evidence_directory"
daemon_architecture="$(docker info --format '{{.Architecture}}')"
[[ "$daemon_architecture" == amd64 || "$daemon_architecture" == x86_64 ]] || {
  echo "qualification requires a native AMD64 Docker daemon, found $daemon_architecture" >&2
  exit 1
}
docker image inspect "$image" > "$evidence_directory/image.json"
image_id="$(jq -er '.[0].Id' "$evidence_directory/image.json")"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
backend="$(jq -er '.[0].Config.Env[] | select(startswith("MESH_RUNNER_BACKEND=")) | split("=")[1]' "$evidence_directory/image.json")"
[[ "$backend" == ui || "$backend" == browser ]] || {
  echo "expected a lean ui or browser image, found $backend" >&2; exit 1;
}
runner_revision="$(jq -er '.[0].Config.Labels["io.mesh-llm.runner-images.revision"]' "$evidence_directory/image.json")"
[[ "$runner_revision" =~ ^[0-9a-f]{40}$ ]]
jq -e --arg revision "$source_revision" '
  length == 1 and .[0].Os == "linux" and .[0].Architecture == "amd64"
  and .[0].Config.Labels["io.mesh-llm.source.revision"] == $revision
' "$evidence_directory/image.json" >/dev/null || {
  echo "image must be Linux AMD64 and declare MeshLLM source revision $source_revision" >&2
  exit 1
}

cat > "$evidence_directory/container.sh" <<'CONTAINER'
set -euo pipefail
backend="$1"
source_revision="$2"
runner_revision="$3"
[[ "$HOME" == /github/home && "${ONNXRUNTIME_NODE_INSTALL:-}" == skip ]]
work="$(mktemp -d /tmp/mesh-ui-qualification.XXXXXX)"
trap 'rm -rf "$work"' EXIT
tar -xf - -C "$work"
cd "$work/crates/mesh-llm-ui"
expected_playwright=none
if [[ "$backend" == browser ]]; then
  expected_playwright="$(node -p 'require("./package.json").devDependencies["@playwright/test"]')"
fi
verify-runner-image public "$backend" "$source_revision" none none "$runner_revision" "$expected_playwright"
test ! -e node_modules
[[ "$(pnpm store path)" == /home/runner/.local/share/pnpm/store/* ]]

check_gpu_side_effects() {
  python3 - "$PWD/node_modules" /home/runner/.local/share/pnpm/store <<'PY'
import json
import re
import sys
from pathlib import Path

gpu_file = re.compile(r"^(?:lib)?(?:onnxruntime_providers_(?:cuda|tensorrt)|cudart|cublas(?:Lt)?|cudnn[^/]*|nvinfer[^/]*)\.(?:so(?:\.[0-9.]+)?|dll)$", re.I)

def inspect_keys(value, index):
    if isinstance(value, dict):
        for key, child in value.items():
            if gpu_file.fullmatch(key.rsplit("/", 1)[-1]):
                raise SystemExit(f"GPU runtime side-effect entry in {index}: {key}")
            inspect_keys(child, index)
    elif isinstance(value, list):
        for child in value:
            inspect_keys(child, index)

for root in map(Path, sys.argv[1:]):
    if not root.exists():
        continue
    for path in root.rglob("*"):
        if gpu_file.fullmatch(path.name):
            raise SystemExit(f"Unexpected GPU runtime side-effect file: {path}")
        # pnpm's files use content hashes; inspect its index mappings as well.
        if root.name == "store" and path.suffix == ".json" and path.is_file():
            inspect_keys(json.loads(path.read_text()), path)
print("No CUDA or TensorRT runtime side-effect files or store entries")
PY
}
check_gpu_side_effects
started=$SECONDS
# Explicitly enable lifecycle scripts even if package-manager config disables
# them. pnpm may reuse cached side effects; execution evidence is in the log.
pnpm install --offline --frozen-lockfile --ignore-scripts=false
echo "Offline UI installation with lifecycle scripts enabled: $((SECONDS - started))s"
check_gpu_side_effects
for ui_command in lint typecheck test build; do
  started=$SECONDS
  pnpm run "$ui_command"
  echo "UI $ui_command passed in $((SECONDS - started))s"
done
test -s dist/index.html
if [[ "$backend" == browser ]]; then
  resolved_playwright="$(pnpm exec playwright --version | awk 'NR == 1 {print $NF}')"
  [[ "$resolved_playwright" == "$expected_playwright" ]]
  started=$SECONDS
  pnpm run test:e2e
  echo "Browser E2E passed in $((SECONDS - started))s"
fi
check_gpu_side_effects
echo "Immutable MeshLLM UI qualification passed: $source_revision ($backend)"
CONTAINER
container_script="$(cat "$evidence_directory/container.sh")"

started=$SECONDS
git -C "$source_repository" archive "$source_revision" \
  | docker run --rm --interactive --pull=never --network none \
      --platform linux/amd64 --shm-size=1g --user root \
      --env HOME=/github/home --env CI=true \
      --entrypoint /bin/bash "$image_id" -c "$container_script" ui-image \
      "$backend" "$source_revision" "$runner_revision" \
  2>&1 | tee "$evidence_directory/qualification.log"
jq -n --arg source "$source_revision" --arg image "$image" --arg image_id "$image_id" --arg backend "$backend" \
  --argjson elapsed "$((SECONDS - started))" \
  '{schema: 1, source_revision: $source, image: $image, image_id: $image_id, backend: $backend,
    network: "none", lifecycle_scripts_enabled: true, elapsed_seconds: $elapsed, passed: true}' \
  > "$evidence_directory/result.json"
echo "UI image qualification passed; evidence: $evidence_directory"
