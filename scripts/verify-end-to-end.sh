#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/mesh-llm/mesh-llm-cuda-runner}"
public_tag="${PUBLIC_TAG:-public-latest}"
self_hosted_tag="${SELF_HOSTED_TAG:-self-hosted-latest}"
all_backends=false
repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for argument in "$@"; do
  case "$argument" in
    --all-backends) all_backends=true ;;
    *) echo "unknown argument: $argument" >&2; exit 2 ;;
  esac
done

require_command() {
  command -v "$1" >/dev/null || { echo "missing required command: $1" >&2; exit 1; }
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
    docker run --rm --platform "linux/$architecture" --entrypoint /usr/local/bin/verify-runner-image \
      "$reference" "$environment" "$backend" "" "$cuda_series" "$rocm_version" "" "$playwright_version"
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
  local reference="$image:$tag"
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
verify_manifest_list "$image:$self_hosted_tag" amd64 arm64
# The mixed compatibility index intentionally combines CUDA12 AMD64 and CPU ARM64.
verify_local_execution "$image:$self_hosted_tag" self-hosted cuda "$cuda12_series" none none amd64
verify_local_execution "$image:$self_hosted_tag" self-hosted cpu none none none arm64

if [[ "$all_backends" == true ]]; then
  while IFS=$'\t' read -r environment backend_id backend cuda_series rocm_version architecture_list; do
    IFS=, read -r -a architectures <<< "$architecture_list"
    expected_playwright=none
    if [[ "$backend" == web ]]; then expected_playwright="$playwright_version"; fi
    verify_image "$environment-$backend_id-latest" "$environment" "$backend" \
      "$cuda_series" "$rocm_version" "$expected_playwright" "${architectures[@]}"
  done <<< "$family_rows"
fi

echo "runner image verification passed"
