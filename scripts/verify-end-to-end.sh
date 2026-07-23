#!/usr/bin/env bash
set -euo pipefail

image="${IMAGE:-ghcr.io/mesh-llm/mesh-llm-cuda-runner}"
public_tag="${PUBLIC_TAG:-public-latest}"
self_hosted_tag="${SELF_HOSTED_TAG:-self-hosted-latest}"
cluster_checks=false
all_backends=false

for argument in "$@"; do
  case "$argument" in
    --cluster) cluster_checks=true ;;
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

verify_cluster() {
  require_command kubectl
  if command -v flux >/dev/null; then
    flux reconcile kustomization cluster-apps --with-source
    flux get helmreleases --all-namespaces
  else
    requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    kubectl annotate gitrepository/patio51-cluster -n flux-system \
      "reconcile.fluxcd.io/requestedAt=$requested_at" --overwrite
    kubectl annotate kustomization/cluster-apps -n flux-system \
      "reconcile.fluxcd.io/requestedAt=$requested_at" --overwrite
    kubectl wait --for=condition=Ready kustomization/cluster-apps -n flux-system --timeout=5m
    kubectl get helmreleases.helm.toolkit.fluxcd.io --all-namespaces
  fi
  kubectl wait --for=condition=Ready helmrelease/arc-controller -n arc-systems --timeout=5m
  kubectl wait --for=condition=Ready helmrelease/mesh-llm-arm64 -n arc-runners --timeout=5m
  kubectl wait --for=condition=Ready helmrelease/mesh-llm-amd64 -n arc-runners --timeout=5m
  kubectl get autoscalingrunnersets.actions.github.com -n arc-runners -o wide
  kubectl get pods -n arc-runners \
    -o 'custom-columns=NAME:.metadata.name,ARCH:.spec.nodeSelector.kubernetes\.io/arch,IMAGE:.spec.containers[0].image,NODE:.spec.nodeName'
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

if [[ "$cluster_checks" == true ]]; then
  verify_cluster
fi

echo "runner image verification passed"
