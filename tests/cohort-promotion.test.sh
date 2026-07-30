#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
generator="$repository_root/scripts/generate-latest-cohort.sh"
reconciler="$repository_root/scripts/reconcile-image-cohort.sh"
mock_docker="$repository_root/tests/fixtures/mock-docker.sh"
fixture="$repository_root/tests/fixtures/candidate-index-valid.json"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

image=ghcr.io/mesh-llm/mesh-llm-cuda-runner
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mesh_revision=2222222222222222222222222222222222222222
runner_images_revision=1111111111111111111111111111111111111111
timestamp=20260729123456
descriptor_directory="$temporary_directory/descriptors"
mkdir -p "$descriptor_directory"
cp "$fixture" "$descriptor_directory/candidate-index-public-cuda12.json"

jq -n '{
  include: [{
    environment: "public",
    backend_id: "cuda12",
    backend_name: "cuda",
    cuda_series: "12-9",
    rocm_version: "none",
    architectures: "amd64,arm64",
    artifact: "candidate-index-public-cuda12",
    tag_stem: "public-cuda12",
    compatibility_tag_stem: ""
  }]
}' > "$temporary_directory/matrix.json"

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

generation_log="$temporary_directory/generate.log"
MOCK_DOCKER_LOG="$generation_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
DOCKER_BIN="$mock_docker" \
  bash "$generator" \
    --descriptors "$descriptor_directory" \
    --matrix "$temporary_directory/matrix.json" \
    --image "$image" \
    --timestamp "$timestamp" \
    --mesh-revision "$mesh_revision" \
    --runner-images-revision "$runner_images_revision" \
    --output "$temporary_directory/cohort.json"

jq -e \
  --arg digest "$digest" \
  --arg image "$image" \
  '
    .schema == 1
    and .type == "mesh-llm-runner-image-latest-cohort"
    and .image == $image
    and .entries == [{
      artifact: "candidate-index-public-cuda12",
      tag: ($image + ":public-cuda12-latest"),
      target_digest: $digest,
      previous_digest: $digest
    }]
  ' "$temporary_directory/cohort.json" >/dev/null

reconcile_log="$temporary_directory/reconcile.log"
MOCK_DOCKER_LOG="$reconcile_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
DOCKER_BIN="$mock_docker" \
  bash "$reconciler" "$temporary_directory/cohort.json" target
grep -Fq "buildx imagetools create --tag $image:public-cuda12-latest" \
  "$reconcile_log"

missing_previous_log="$temporary_directory/missing-previous.log"
MOCK_DOCKER_LOG="$missing_previous_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
MOCK_DOCKER_MISSING_TAG_PATTERN="-latest" \
DOCKER_BIN="$mock_docker" \
  bash "$generator" \
    --descriptors "$descriptor_directory" \
    --matrix "$temporary_directory/matrix.json" \
    --image "$image" \
    --timestamp "$timestamp" \
    --mesh-revision "$mesh_revision" \
    --runner-images-revision "$runner_images_revision" \
    --output "$temporary_directory/new-cohort.json"
jq -e '.entries[0].previous_digest == null' \
  "$temporary_directory/new-cohort.json" >/dev/null

duplicate_manifest="$temporary_directory/duplicate.json"
jq '.entries += [.entries[0]]' "$temporary_directory/cohort.json" \
  > "$duplicate_manifest"
expect_failure env \
  MOCK_DOCKER_LOG="$temporary_directory/duplicate.log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  DOCKER_BIN="$mock_docker" \
  bash "$reconciler" "$duplicate_manifest" target

echo "latest cohort reconciliation contract passed"
