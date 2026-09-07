#!/usr/bin/env bash
set -euo pipefail

# Opt-in real BuildKit proof. Builds local images; never publishes or prunes.
# Prepared context must contain Dockerfile and build-context/manifests bundles.
# Logs, fixture context, image references, and parsed evidence are retained.
# --with-vulkan uses Vulkan for all three mutation phases, then switches to CPU
# to prove SDK reuse across dependency changes and store reuse across backends.
usage() {
  echo "usage: layer-cache.sh PREPARED_CONTEXT [--platform linux/arm64|linux/amd64] [--log-root DIRECTORY] [--with-vulkan]" >&2
  echo "       layer-cache.sh --evidence-only PROOF_DIRECTORY" >&2
  exit 2
}
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
evidence_only=false
if [[ "${1:-}" == --evidence-only ]]; then
  [[ $# -eq 2 ]] || usage
  evidence_only=true
  proof_directory="$(cd "$2" && pwd -P)"
  with_vulkan="$(jq -er '.with_vulkan | select(type == "boolean") | tostring' "$proof_directory/inputs.json")"
else
[[ $# -ge 1 && "$1" != -* ]] || usage
prepared_context="$(cd "$1" && pwd -P)"
shift
platform=linux/arm64
log_root=
with_vulkan=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform) [[ $# -ge 2 ]] || usage; platform="$2"; shift 2 ;;
    --log-root) [[ $# -ge 2 && -n "$2" ]] || usage; log_root="$2"; shift 2 ;;
    --with-vulkan) with_vulkan=true; shift ;;
    *) usage ;;
  esac
done
[[ "$platform" == linux/arm64 || "$platform" == linux/amd64 ]] || usage
baseline_backend=cpu
if [[ "$with_vulkan" == true ]]; then baseline_backend=vulkan; fi
for required_command in docker jq python3 git; do
  command -v "$required_command" >/dev/null || {
    echo "missing required command: $required_command" >&2
    exit 1
  }
done
runner_images_revision="${RUNNER_IMAGES_REVISION:-$(git -C "$repository_root" rev-parse HEAD)}"
[[ "$runner_images_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "RUNNER_IMAGES_REVISION must be a full lowercase Git SHA" >&2
  exit 1
}
if [[ -n "$log_root" ]]; then
  mkdir -p "$log_root"
  proof_directory="$(mktemp -d "$log_root/layer-cache.XXXXXX")"
else
  proof_directory="$(mktemp -d "${TMPDIR:-/tmp}/mesh-runner-layer-cache.XXXXXX")"
fi
proof_directory="$(cd "$proof_directory" && pwd -P)"
echo "Retaining layer cache proof in $proof_directory"
trap 'status=$?; if (( status != 0 )); then echo "Layer cache proof failed; evidence retained in $proof_directory" >&2; fi' EXIT
context="$proof_directory/context"
mkdir -p "$context"
for context_file in Dockerfile Dockerfile.verify .dockerignore; do
  cp "$prepared_context/$context_file" "$context/"
done
for context_directory in profiles scripts config build-context; do
  cp -R "$prepared_context/$context_directory" "$context/"
done
mesh_revision="$(cat "$context/build-context/manifests/public/source-revision.txt")"
[[ "$mesh_revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "bundle source revision must be a full lowercase Git SHA" >&2
  exit 1
}
for environment in public self-hosted; do
  bundle="$context/build-context/manifests/$environment"
  [[ "$(cat "$bundle/source-revision.txt")" == "$mesh_revision" ]]
  jq -e --arg revision "$mesh_revision" '.source_revision == $revision' \
    "$bundle/manifest-index.json" >/dev/null
  test -s "$bundle/dependencies/dependency-index.json"
done
run_id="$(basename "$proof_directory" | tr '[:upper:]' '[:lower:]')"
# Unique, explicitly synthetic provenance prevents a previous proof's fixture
# from making the dependency-change test accidentally reuse an old cache hit.
fixture_revision="$(python3 - "$mesh_revision" "$run_id" <<'PY'
import hashlib
import sys
print(hashlib.sha256((sys.argv[1] + ":layer-cache-fixture:" + sys.argv[2]).encode()).hexdigest()[:40])
PY
)"
jq -n --arg original "$mesh_revision" --arg fixture "$fixture_revision" \
  --arg runner "$runner_images_revision" --arg platform "$platform" \
  --arg baseline_backend "$baseline_backend" \
  --argjson with_vulkan "$with_vulkan" \
  '{schema: 1, original_mesh_revision: $original, synthetic_fixture_revision: $fixture,
    runner_images_revision: $runner, platform: $platform, baseline_backend: $baseline_backend,
    with_vulkan: $with_vulkan}' \
  > "$proof_directory/inputs.json"
fi

build_image() {
  local phase="$1" backend="$2" revision="$3"
  local image="mesh-runner-layer-cache:$run_id-$phase"
  local arguments=(buildx build --progress=plain --load --platform "$platform"
    --target public-test --tag "$image" --file "$context/Dockerfile"
    --build-arg BACKEND="$backend" --build-arg RUNNER_ENVIRONMENT=public
    --build-arg CUDA_SERIES=none --build-arg ROCM_VERSION=none
    --build-arg MESH_LLM_REVISION="$revision"
    --build-arg RUNNER_IMAGES_REVISION="$runner_images_revision")
  if [[ -n "${ACTIONS_RUNNER_BASE_IMAGE:-}" ]]; then
    arguments+=(--build-arg ACTIONS_RUNNER_BASE_IMAGE="$ACTIONS_RUNNER_BASE_IMAGE")
  fi
  arguments+=("$context")
  printf '%s\n' "$image" > "$proof_directory/$phase-image.txt"
  jq -n --args '$ARGS.positional' -- docker "${arguments[@]}" \
    > "$proof_directory/$phase-command.json"
  echo "Building $phase ($backend) -> $image"
  docker "${arguments[@]}" 2>&1 | tee "$proof_directory/$phase.log"
}

assert_cache_evidence() {
  local phase="$1"
  if [[ "$phase" == cpu-switch ]]; then
    # COPY --link can be logged as a DONE merge despite reusing the exact
    # content layer. Require actual filesystem identities, never just DONE.
    for inspected_phase in dependency-change cpu-switch; do
      local_image="$(cat "$proof_directory/$inspected_phase-image.txt")"
      [[ "$local_image" == mesh-runner-layer-cache:* ]] || {
        echo "unexpected local proof image: $local_image" >&2; return 1;
      }
      docker image inspect "$local_image" > "$proof_directory/$inspected_phase-inspect.json"
      local_image_id="$(jq -er '.[0].Id' "$proof_directory/$inspected_phase-inspect.json")"
      docker history --no-trunc --human=false --format '{{json .}}' "$local_image_id" \
        > "$proof_directory/$inspected_phase-history.jsonl"
    done
    python3 "$repository_root/tests/integration/compare-dependency-layers.py" "$proof_directory"
  fi
  python3 - "$proof_directory/$phase.log" "$phase" \
    "$proof_directory/$phase-proof.json" <<'PY'
import json
import re
import sys
from pathlib import Path

log_path, phase, output_path = sys.argv[1:]
steps = {}
statuses = {}
for line in Path(log_path).read_text().splitlines():
    header = re.match(r"^(#\d+) \[([^\]]+)\] (RUN|COPY) (.*)$", line)
    if header:
        step_id, label, operation, command = header.groups()
        parts = label.split()
        if len(parts) >= 2 and re.fullmatch(r"\d+/\d+", parts[-1]):
            steps[step_id] = {"id": step_id, "stage": parts[-2],
                              "operation": operation, "command": command}
    terminal = re.match(r"^(#\d+) (CACHED|DONE)(?:\s.*)?$", line)
    if terminal:
        statuses[terminal.group(1)] = terminal.group(2)

def fail(message):
    raise SystemExit(f"{phase}: {message}; see {log_path}")

def one(name, predicate):
    matches = [step for step in steps.values() if predicate(step)]
    if len(matches) != 1:
        fail(f"expected exactly one {name} step, found {len(matches)}")
    return matches[0]

warm = one("dependency warming", lambda step: step["stage"] == "dependencies"
           and step["operation"] == "RUN"
           and "/usr/local/bin/warm-dependencies /opt/mesh-llm/manifests" in step["command"])
one("core tool installation", lambda step: step["stage"] == "toolchain"
    and step["operation"] == "RUN" and "/usr/local/bin/install-core-tools" in step["command"])
one("common package installation", lambda step: step["stage"] == "toolchain"
    and step["operation"] == "RUN" and "apt-get install" in step["command"])
toolchain = [step for step in steps.values()
             if step["stage"] == "toolchain" and step["operation"] == "RUN"]
backend_packages = one("backend package installation", lambda step:
                       step["stage"] == "selected-backend" and step["operation"] == "RUN"
                       and "profile-packages /tmp/profiles/backend.yml" in step["command"])
copies = []
for source in ("/opt/mesh-llm/", "/home/runner/.cargo/registry/",
               "/home/runner/.cargo/git/", "/home/runner/.npm/",
               "/home/runner/.local/share/pnpm/store/"):
    copies.append(one(f"linked dependency copy {source}", lambda step, source=source:
                      step["stage"] == "selected-backend" and step["operation"] == "COPY"
                      and step["command"].split() == ["--link", "--chown=1001:123",
                                                     "--from=dependencies", source, source]))
tracked = toolchain + [backend_packages, warm] + copies
for step in tracked:
    step["status"] = statuses.get(step["id"])
    if step["status"] not in ("CACHED", "DONE"):
        fail(f"missing successful terminal status for {step['id']}: {step['command']}")

if phase != "baseline":
    for step in toolchain:
        if step["status"] != "CACHED":
            fail(f"toolchain reran: {step['id']} {step['command']}")
    if phase in ("source-change", "dependency-change") and backend_packages["status"] != "CACHED":
        fail(f"backend package installation reran: {backend_packages['id']} {backend_packages['command']}")
    expected_warm = "DONE" if phase == "dependency-change" else "CACHED"
    if warm["status"] != expected_warm:
        fail(f"warm step {warm['id']} was {warm['status']}, expected {expected_warm}")
    if phase == "source-change":
        for step in copies:
            if step["status"] != "CACHED":
                fail(f"linked dependency copy reran: {step['id']} {step['command']}")

Path(output_path).write_text(json.dumps({"schema": 1, "phase": phase,
                                       "log": log_path, "steps": tracked}, indent=2) + "\n")
print(f"{phase}: verified {len(toolchain)} toolchain RUN steps, warm step {warm['id']} "
      f"({warm['status']}), backend package step {backend_packages['id']} "
      f"({backend_packages['status']}), and {len(copies)} linked dependency copies")
PY
}

if [[ "$evidence_only" == true ]]; then
  for retained_phase in baseline source-change dependency-change; do
    assert_cache_evidence "$retained_phase"
  done
  if [[ "$with_vulkan" == true ]]; then assert_cache_evidence cpu-switch; fi
  test -s "$proof_directory/source-change-stamp.log"
  echo "Existing layer cache evidence passed without builds or containers: $proof_directory"
  exit 0
fi

build_image baseline "$baseline_backend" "$mesh_revision"
assert_cache_evidence baseline

# Change only source audit/provenance, leaving dependency bytes untouched.
for environment in public self-hosted; do
  bundle="$context/build-context/manifests/$environment"
  jq --arg revision "$fixture_revision" '.source_revision = $revision' \
    "$bundle/manifest-index.json" > "$bundle/manifest-index.json.new"
  mv "$bundle/manifest-index.json.new" "$bundle/manifest-index.json"
  printf '%s\n' "$fixture_revision" > "$bundle/source-revision.txt"
done
build_image source-change "$baseline_backend" "$fixture_revision"
assert_cache_evidence source-change
source_image="$(cat "$proof_directory/source-change-image.txt")"
docker run --rm --pull=never --network none --platform "$platform" \
  --entrypoint /bin/bash "$source_image" -ceu '
    [[ "$(cat /etc/mesh-llm-revision)" == "$1" ]]
    [[ "$(cat /opt/mesh-llm/manifests/source-revision.txt)" == "$1" ]]
    [[ "$(cat /etc/mesh-runner-images-revision)" == "$2" ]]
    jq -e --arg revision "$1" ".source_revision == \$revision" \
      /opt/mesh-llm/manifests/manifest-index.json >/dev/null
    echo "Synthetic source revision is present in final image stamps and audit metadata"
  ' layer-cache "$fixture_revision" "$runner_images_revision" \
  | tee "$proof_directory/source-change-stamp.log"

# A harmless package-manager configuration comment changes real dependency
# input bytes. Update both indexes so the fixture remains internally coherent.
dependency_path=crates/mesh-llm-ui/.npmrc
for environment in public self-hosted; do
  bundle="$context/build-context/manifests/$environment"
  test -f "$bundle/dependencies/$dependency_path"
  printf '\n# layer cache integration fixture %s\n' "$run_id" \
    >> "$bundle/dependencies/$dependency_path"
  dependency_hash="$(python3 - "$bundle/dependencies/$dependency_path" <<'PY'
import hashlib
import sys
from pathlib import Path
print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
  for index_kind in dependency manifest; do
    if [[ "$index_kind" == dependency ]]; then
      index_file="$bundle/dependencies/dependency-index.json"
      entries_key=files
    else
      index_file="$bundle/manifest-index.json"
      entries_key=manifests
    fi
    jq --arg key "$entries_key" --arg path "$dependency_path" --arg hash "$dependency_hash" '
      if ([.[$key][] | select(.path == $path)] | length) != 1 then
        error("expected exactly one dependency configuration index entry")
      else (.[$key][] | select(.path == $path) | .sha256) = $hash end
    ' "$index_file" > "$index_file.new"
    mv "$index_file.new" "$index_file"
  done
done
build_image dependency-change "$baseline_backend" "$fixture_revision"
assert_cache_evidence dependency-change

if [[ "$with_vulkan" == true ]]; then
  build_image cpu-switch cpu "$fixture_revision"
  assert_cache_evidence cpu-switch
fi
echo "Real BuildKit layer cache proof passed; retained evidence: $proof_directory"
