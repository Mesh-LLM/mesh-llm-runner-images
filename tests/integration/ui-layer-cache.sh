#!/usr/bin/env bash
set -euo pipefail

# Opt-in native AMD64 proof. Honors DOCKER_HOST and uses its default builder.
# All fixture contexts, logs, image IDs, histories and parsed evidence remain
# on disk. Images remain local to the daemon; nothing is published or pruned.
usage() {
  echo "usage: ui-layer-cache.sh PREPARED_CONTEXT --ssh-host HOST --containerd-address PATH --namespace NAME [--sudo] [--baseline-image REF --baseline-log LOG] [--with-ui-switch] [--log-root DIRECTORY]" >&2
  echo "       ui-layer-cache.sh --evidence-only PROOF_DIRECTORY" >&2
  exit 2
}
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
parser="$repository_root/tests/integration/ui-layer-cache.py"
export PYTHONDONTWRITEBYTECODE=1
if [[ "${1:-}" == --evidence-only ]]; then
  [[ $# -eq 2 ]] || usage
  exec python3 "$parser" check "$2"
fi
[[ $# -ge 1 && "$1" != -* ]] || usage
prepared_context="$(cd "$1" && pwd -P)"
shift
baseline_image=
baseline_log=
log_root=
with_ui_switch=false
ssh_host=
containerd_address=
namespace=
use_sudo=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline-image) [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || usage; baseline_image="$2"; shift 2 ;;
    --baseline-log) [[ $# -ge 2 && -n "$2" ]] || usage; baseline_log="$2"; shift 2 ;;
    --with-ui-switch) with_ui_switch=true; shift ;;
    --log-root) [[ $# -ge 2 && -n "$2" ]] || usage; log_root="$2"; shift 2 ;;
    --ssh-host) [[ $# -ge 2 && -n "$2" ]] || usage; ssh_host="$2"; shift 2 ;;
    --containerd-address) [[ $# -ge 2 && -n "$2" ]] || usage; containerd_address="$2"; shift 2 ;;
    --namespace) [[ $# -ge 2 && -n "$2" ]] || usage; namespace="$2"; shift 2 ;;
    --sudo) use_sudo=true; shift ;;
    *) usage ;;
  esac
done
[[ -z "$baseline_image" && -z "$baseline_log" || -n "$baseline_image" && -f "$baseline_log" ]] || usage
[[ -n "$ssh_host" && "$containerd_address" == /* && -n "$namespace" ]] || usage
[[ "$ssh_host" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ ]] || usage
[[ "${DOCKER_HOST:-}" == "ssh://$ssh_host" ]] || {
  echo "DOCKER_HOST must match the explicit metadata SSH host: ssh://$ssh_host" >&2; exit 1;
}
for required_command in docker jq python3 git ssh; do
  command -v "$required_command" >/dev/null || { echo "missing required command: $required_command" >&2; exit 1; }
done
runner_images_revision="${RUNNER_IMAGES_REVISION:-$(git -C "$repository_root" rev-parse HEAD)}"
if [[ -n "$log_root" ]]; then
  mkdir -p "$log_root"
  proof_directory="$(mktemp -d "$log_root/ui-layer-cache.XXXXXX")"
else
  proof_directory="$(mktemp -d "${TMPDIR:-/tmp}/mesh-ui-layer-cache.XXXXXX")"
fi
proof_directory="$(cd "$proof_directory" && pwd -P)"
echo "Retaining lean UI cache proof in $proof_directory"
trap 'status=$?; if (( status != 0 )); then echo "Lean UI cache proof failed; evidence retained in $proof_directory" >&2; fi' EXIT
context="$proof_directory/context"
mkdir -p "$context"
for context_file in Dockerfile.ui .dockerignore; do
  cp "$prepared_context/$context_file" "$context/"
done
for context_directory in profiles scripts config build-context; do
  cp -R "$prepared_context/$context_directory" "$context/"
done
python3 "$parser" initialize "$proof_directory" "$runner_images_revision" "$with_ui_switch"
daemon_platform="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
[[ "$daemon_platform" == linux/amd64 || "$daemon_platform" == linux/x86_64 ]] || {
  echo "cache qualification requires a native Linux AMD64 daemon, found $daemon_platform" >&2; exit 1;
}
printf '%s\n' "$daemon_platform" > "$proof_directory/daemon-platform.txt"
run_id="$(basename "$proof_directory" | tr '[:upper:]' '[:lower:]')"
metadata_arguments=(--ssh-host "$ssh_host" --containerd-address "$containerd_address" --namespace "$namespace")
if [[ "$use_sudo" == true ]]; then metadata_arguments+=(--sudo); fi
jq -n --arg host "$ssh_host" --arg address "$containerd_address" --arg namespace "$namespace" --argjson sudo "$use_sudo" \
  '{ssh_host: $host, containerd_address: $address, namespace: $namespace, sudo: $sudo}' > "$proof_directory/metadata-transport.json"

# This fixed program reads metadata; no script or command from the image is
# evaluated. Capture the actual stamps and indexes from the immutable image ID.
cat > "$proof_directory/read-image-metadata.py" <<'PY'
import hashlib
import json
from pathlib import Path

root = Path("/opt/mesh-llm/manifests")
index = json.loads((root / "dependency-index.json").read_text())
for entry in index["files"]:
    path = (root / entry["path"]).resolve()
    if root not in path.parents or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
        raise SystemExit("installed UI dependency bytes do not match the index")
print(json.dumps({
    "source_revision": Path("/etc/mesh-llm-revision").read_text().strip(),
    "runner_images_revision": Path("/etc/mesh-runner-images-revision").read_text().strip(),
    "bundle_source_revision": (root / "source-revision.txt").read_text().strip(),
    "profile": (root / "profile.txt").read_text().strip(),
    "backend": Path("/etc/mesh-runner-backend").read_text().strip(),
    "manifest_index": json.loads((root / "manifest-index.json").read_text()),
    "dependency_index": index,
}))
PY
metadata_reader="$(cat "$proof_directory/read-image-metadata.py")"

capture_image() {
  local phase="$1" reference="$2" image_id
  printf '%s\n' "$reference" > "$proof_directory/$phase-image.txt"
  docker image inspect "$reference" > "$proof_directory/$phase-inspect.json"
  image_id="$(jq -er 'select(length == 1) | .[0].Id' "$proof_directory/$phase-inspect.json")"
  [[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]]
  python3 "$repository_root/scripts/measure-image-layers.py" --local "$image_id" \
    --platform linux/amd64 --include-config "${metadata_arguments[@]}" > "$proof_directory/$phase-oci.json"
  docker run --rm --pull=never --network none --platform linux/amd64 --user root \
    --entrypoint python3 "$image_id" -c "$metadata_reader" \
    > "$proof_directory/$phase-metadata.json"
  python3 "$parser" check-phase "$proof_directory" "$phase"
}

build_image() {
  local phase="$1" backend="$2" revision image
  revision="$(jq -er '.source_revision' "$proof_directory/$phase-expected.json")"
  image="mesh-runner-ui-cache:$run_id-$phase"
  local arguments=(buildx build --builder default --progress=plain --load --platform linux/amd64
    --target public-test --tag "$image" --file "$context/Dockerfile.ui"
    --build-arg BACKEND="$backend" --build-arg RUNNER_ENVIRONMENT=public
    --build-arg CUDA_SERIES=none --build-arg ROCM_VERSION=none
    --build-arg MESH_LLM_REVISION="$revision" --build-arg RUNNER_IMAGES_REVISION="$runner_images_revision")
  if [[ -n "${ACTIONS_RUNNER_BASE_IMAGE:-}" ]]; then
    arguments+=(--build-arg ACTIONS_RUNNER_BASE_IMAGE="$ACTIONS_RUNNER_BASE_IMAGE")
  fi
  arguments+=("$context")
  jq -n --args '$ARGS.positional' -- docker "${arguments[@]}" > "$proof_directory/$phase-command.json"
  echo "Building $phase ($backend) -> $image"
  docker "${arguments[@]}" 2>&1 | tee "$proof_directory/$phase.log"
  capture_image "$phase" "$image"
}

if [[ -n "$baseline_image" ]]; then
  cp "$baseline_log" "$proof_directory/baseline.log"
  jq -n --arg image "$baseline_image" --arg log "$baseline_log" \
    '{mode: "import-existing-completed-public-test", image: $image, log: $log}' > "$proof_directory/baseline-command.json"
  capture_image baseline "$baseline_image"
else
  build_image baseline browser
fi
for phase in unrelated-change ui-config-change; do
  python3 "$parser" mutate "$proof_directory" "$phase"
  build_image "$phase" browser
done
if [[ "$with_ui_switch" == true ]]; then
  python3 "$parser" ui-switch "$proof_directory"
  build_image ui-switch ui
fi
python3 "$parser" check "$proof_directory"
