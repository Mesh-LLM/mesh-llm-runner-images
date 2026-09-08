#!/usr/bin/env bash
set -euo pipefail

# Offline native runtime proof against a retained local image. This does not
# publish an image or qualify a hosted workflow run. SSH containerd access is
# explicit and reads metadata only, never layer blobs.
if [[ $# -lt 8 || $# -gt 9 || "$1" == -* ]]; then
  echo 'usage: runner-identity.sh LOCAL_IMAGE SSH_HOST ENV BACKEND MESH_SHA CUDA ROCM RUNNER_SHA [LOG_DIRECTORY]' >&2
  exit 2
fi
image="$1" ssh_host="$2" environment="$3" backend="$4" mesh_revision="$5"
cuda_series="$6" rocm_version="$7" runner_revision="$8"
[[ "$ssh_host" =~ ^[A-Za-z0-9_][A-Za-z0-9_.@-]*$ ]]
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
verifier_revision="$(git -C "$repository_root" rev-parse HEAD)"
if [[ $# -eq 9 ]]; then
  mkdir -p "$9"
  evidence="$(mktemp -d "$9/runner-identity.XXXXXX")"
else
  evidence="$(mktemp -d "${TMPDIR:-/tmp}/runner-identity.XXXXXX")"
fi
evidence="$(cd "$evidence" && pwd -P)"
echo "Retaining local identity proof in $evidence"
docker_command=(docker --host "ssh://$ssh_host")
"${docker_command[@]}" image inspect "$image" > "$evidence/image.json"
image_id="$(jq -er '.[0].Id | select(test("^sha256:[0-9a-f]{64}$"))' "$evidence/image.json")"
architecture="$(jq -er '.[0].Architecture' "$evidence/image.json")"
daemon_architecture="$("${docker_command[@]}" info --format '{{.Architecture}}')"
case "$daemon_architecture" in x86_64) daemon_architecture=amd64 ;; aarch64) daemon_architecture=arm64 ;; esac
[[ "$architecture" == "$daemon_architecture" && "$architecture" =~ ^(amd64|arm64)$ ]]
platform="linux/$architecture"
expected_playwright=none
if [[ "$backend" == web || "$backend" == browser ]]; then
  expected_playwright="$(cat "$repository_root/config/playwright-pin.txt")"
fi
mkdir -p "$evidence/expected"
cp "$repository_root"/config/{playwright-pin.txt,tool-pins.json,cache-policy.json,python-requirements.lock} "$evidence/expected/"
cp "$repository_root"/scripts/{verify-runner-candidate.sh,verify-runner-image.sh,collect-runner-identity.py} "$evidence/expected/"
cat > "$evidence/container.sh" <<'CONTAINER'
set -euo pipefail
work="$(mktemp -d /tmp/runner-identity.XXXXXX)"
trap 'rm -rf "$work"' EXIT
tar -xf - -C "$work"
verifier="$1"
shift
bash "$work/verify-runner-candidate.sh" --expected-directory "$work" --verifier-revision "$verifier" "$@"
CONTAINER
container_script="$(cat "$evidence/container.sh")"
tar -C "$evidence/expected" -cf - . \
  | "${docker_command[@]}" run --rm --interactive --pull=never --network none \
      --platform "$platform" --entrypoint /bin/bash "$image_id" -c "$container_script" runner-identity \
      "$verifier_revision" "$environment" "$backend" "$mesh_revision" "$cuda_series" "$rocm_version" \
      "$runner_revision" "$expected_playwright" > "$evidence/runtime-identity.json" 2> "$evidence/verification.log"
python3 "$repository_root/scripts/measure-image-layers.py" --local "$image_id" --platform "$platform" \
  --ssh-host "$ssh_host" --containerd-address /run/containerd/containerd.sock --namespace moby --sudo \
  > "$evidence/layers.json"
root_digest="$(jq -er '.identity.root.digest' "$evidence/layers.json")"
child_digest="$(jq -er '.identity.manifest.digest' "$evidence/layers.json")"
[[ "$root_digest" == "$image_id" ]] || {
  echo 'This proof requires Docker image IDs to address the retained OCI root digest' >&2
  exit 1
}
ssh -- "$ssh_host" "sudo -n ctr --address /run/containerd/containerd.sock --namespace moby content get $root_digest" > "$evidence/index.json"
ssh -- "$ssh_host" "sudo -n ctr --address /run/containerd/containerd.sock --namespace moby content get $child_digest" > "$evidence/manifest.json"
backend_id="$backend"
if [[ "$backend" == cuda ]]; then backend_id="cuda${cuda_series%%-*}"; fi
if [[ "$backend" == rocm ]]; then
  IFS=. read -r rocm_major rocm_minor _ <<< "$rocm_version"
  backend_id="rocm${rocm_major}${rocm_minor}"
fi
jq -n --arg backend_id "$backend_id" --arg digest "$root_digest" --arg child "$child_digest" \
  --slurpfile runtime "$evidence/runtime-identity.json" '
  $runtime[0] as $r | {
    schema: 1, type: "mesh-llm-runner-image-platform-candidate",
    image: "ghcr.io/mesh-llm/mesh-llm-cuda-runner", environment: $r.family.environment,
    backend: {id: $backend_id, name: $r.family.backend, cuda_series: $r.family.cuda_series, rocm_version: $r.family.rocm_version},
    mesh_revision: $r.source.mesh_revision, runner_images_revision: $r.source.runner_images_revision,
    platform: $r.platform, digest: $digest, child_digest: $child
  }' > "$evidence/candidate.json"
python3 "$repository_root/scripts/bind-runner-identity.py" --runtime "$evidence/runtime-identity.json" \
  --candidate "$evidence/candidate.json" --index "$evidence/index.json" --manifest "$evidence/manifest.json" \
  --expected-directory "$evidence/expected" --verifier-revision "$verifier_revision" --output "$evidence/identity.json"
jq -n --arg image "$image" --arg digest "$root_digest" --arg verifier "$verifier_revision" \
  '{schema: 1, passed: true, kind: "local-offline-runtime-proof", image: $image, digest: $digest,
    verifier_checkout_revision: $verifier, hosted_workflow_qualified: false, registry_publication_verified: false}' \
  > "$evidence/result.json"
echo "Local runtime identity proof passed: $evidence"
