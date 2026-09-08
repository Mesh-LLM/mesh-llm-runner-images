#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/mesh-llm/mesh-llm-cuda-runner}"
public_tag="${PUBLIC_TAG:-public-latest}"
self_hosted_tag="${SELF_HOSTED_TAG:-self-hosted-latest}"
all_backends=false
expected_mesh_revision=
expected_runner_images_revision=
resolved_aliases='{}'
resolved_reference=
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

while (( $# > 0 )); do
  case "$1" in
    --all-backends) all_backends=true; shift ;;
    --mesh-revision|--runner-images-revision)
      [[ "${2:-}" =~ ^[0-9a-f]{40}$ ]] || {
        echo "$1 requires a full lowercase git SHA" >&2
        exit 2
      }
      if [[ "$1" == --mesh-revision ]]; then expected_mesh_revision="$2"
      else expected_runner_images_revision="$2"; fi
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null || { echo "missing required command: $1" >&2; exit 1; }
}

resolve_alias() {
  local alias_reference="$1" digest manifest
  digest="$(jq -r --arg reference "$alias_reference" '.[$reference] // empty' <<< "$resolved_aliases")"
  if [[ -z "$digest" ]]; then
    manifest="$(docker buildx imagetools inspect "$alias_reference" --format '{{json .Manifest}}')"
    digest="$(jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' <<< "$manifest")"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "registry returned no single valid digest for $alias_reference" >&2
      exit 1
    }
    resolved_aliases="$(jq --arg reference "$alias_reference" --arg digest "$digest" \
      '.[$reference] = $digest' <<< "$resolved_aliases")"
  fi
  resolved_reference="$image@$digest"
}

verify_manifest_list() {
  local reference="$1"
  shift
  local raw
  raw="$(docker buildx imagetools inspect --raw "$reference")"
  for architecture in "$@"; do
    jq -e --arg architecture "$architecture" \
      '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $architecture)' \
      <<<"$raw" >/dev/null
  done
}

verify_local_execution() {
  local reference="$1"
  local environment="$2"
  local backend="$3"
  local cuda_series="$4"
  local rocm_version="$5"
  local playwright_version="$6"
  shift 6
  for architecture in "$@"; do
    # The daemon may pull this exact digest; the verification process is offline.
    docker run --rm --pull=missing --network none --platform "linux/$architecture" --entrypoint /usr/local/bin/verify-runner-image \
      "$reference" "$environment" "$backend" "$expected_mesh_revision" "$cuda_series" "$rocm_version" \
      "$expected_runner_images_revision" "$playwright_version"
  done
}

verify_image() {
  local tag="$1"
  local environment="$2"
  local backend="$3"
  local cuda_series="$4"
  local rocm_version="$5"
  local playwright_version="$6"
  shift 6
  resolve_alias "$image:$tag"
  local reference="$resolved_reference"
  verify_manifest_list "$reference" "$@"
  verify_local_execution "$reference" "$environment" "$backend" "$cuda_series" "$rocm_version" "$playwright_version" "$@"
}

require_command docker
require_command jq

# Finish catalog generation before any registry access. A failed producer in
# process substitution would otherwise be invisible to the verification loop.
matrices="$(bash "$repository_root/scripts/generate-workflow-matrices.sh")"
family_rows="$(jq -er '.family_matrix.include[] |
  [.environment, .backend_id, .backend_name, .cuda_series, .rocm_version, .architectures] | @tsv' <<< "$matrices")"
cuda12_series="$(jq -er '.family_matrix.include[] |
  select(.environment == "self-hosted" and .backend_id == "cuda12") | .cuda_series' <<< "$matrices")"
playwright_version="$(cat "$repository_root/config/playwright-pin.txt")"
[[ "$playwright_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "invalid Playwright version pin" >&2
  exit 1
}

verify_image "$public_tag" public cpu none none none amd64 arm64
resolve_alias "$image:$self_hosted_tag"
self_hosted_reference="$resolved_reference"
verify_manifest_list "$self_hosted_reference" amd64 arm64
# The mixed compatibility index intentionally combines CUDA12 AMD64 and CPU ARM64.
verify_local_execution "$self_hosted_reference" self-hosted cuda "$cuda12_series" none none amd64
verify_local_execution "$self_hosted_reference" self-hosted cpu none none none arm64

if [[ "$all_backends" == true ]]; then
  while IFS=$'\t' read -r environment backend_id backend cuda_series rocm_version architecture_list; do
    IFS=, read -r -a architectures <<< "$architecture_list"
    expected_playwright=none
    if [[ "$backend" == web || "$backend" == browser ]]; then expected_playwright="$playwright_version"; fi
    verify_image "$environment-$backend_id-latest" "$environment" "$backend" \
      "$cuda_series" "$rocm_version" "$expected_playwright" "${architectures[@]}"
  done <<< "$family_rows"
fi

echo "runner image verification passed"
