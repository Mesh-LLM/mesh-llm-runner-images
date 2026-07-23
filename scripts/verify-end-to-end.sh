#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/mesh-llm/mesh-llm-cuda-runner}"
public_tag="${PUBLIC_TAG:-public-latest}"
self_hosted_tag="${SELF_HOSTED_TAG:-self-hosted-latest}"
all_backends=false

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
  shift 3
  for architecture in "$@"; do
    docker run --rm --platform "linux/$architecture" --entrypoint /usr/local/bin/verify-runner-image \
      "$reference" "$environment" "$backend"
  done
}

verify_image() {
  local tag="$1"
  local environment="$2"
  local backend="$3"
  shift 3
  local reference="$image:$tag"
  verify_manifest_list "$reference" "$@"
  verify_local_execution "$reference" "$environment" "$backend" "$@"
}

require_command docker
require_command jq

verify_image "$public_tag" public cpu amd64 arm64
verify_manifest_list "$image:$self_hosted_tag" amd64 arm64
verify_local_execution "$image:$self_hosted_tag" self-hosted cuda amd64
verify_local_execution "$image:$self_hosted_tag" self-hosted cpu arm64

if [[ "$all_backends" == true ]]; then
  for environment in public self-hosted; do
    verify_image "$environment-cpu-latest" "$environment" cpu amd64 arm64
    verify_image "$environment-vulkan-latest" "$environment" vulkan amd64 arm64
    verify_image "$environment-cuda12-latest" "$environment" cuda amd64 arm64
    verify_image "$environment-cuda13-latest" "$environment" cuda amd64 arm64
    verify_image "$environment-rocm70-latest" "$environment" rocm amd64
    verify_image "$environment-rocm72-latest" "$environment" rocm amd64
  done
fi

echo "runner image verification passed"
