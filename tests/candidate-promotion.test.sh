#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$repository_root/scripts/validate-candidate-descriptor.sh"
promoter="$repository_root/scripts/promote-image-digest.sh"
fixture="$repository_root/tests/fixtures/candidate-index-valid.json"
mock_docker="$repository_root/tests/fixtures/mock-docker.sh"
raw_manifest_fixture="$repository_root/tests/fixtures/candidate-index-manifest.json"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

image=ghcr.io/mesh-llm/mesh-llm-cuda-runner
runner_images_revision=1111111111111111111111111111111111111111
mesh_revision=2222222222222222222222222222222222222222
digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mismatch_digest=sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
validation_arguments=(
  --descriptor "$fixture"
  --image "$image"
  --environment public
  --backend-id cuda12
  --backend-name cuda
  --cuda-series 12-9
  --rocm-version none
  --mesh-revision "$mesh_revision"
  --runner-images-revision "$runner_images_revision"
  --architectures "amd64,arm64"
)

expect_failure() {
  if "$@" >/dev/null 2>&1; then
    echo "expected command to fail: $*" >&2
    exit 1
  fi
}

bash "$validator" "${validation_arguments[@]}"

extra_key_descriptor="$temporary_directory/extra-key.json"
jq '.unexpected = true' "$fixture" > "$extra_key_descriptor"
expect_failure bash "$validator" \
  "${validation_arguments[@]/"$fixture"/"$extra_key_descriptor"}"

duplicate_architecture_descriptor="$temporary_directory/duplicate-architecture.json"
jq '.children[1].architecture = "amd64"' "$fixture" > "$duplicate_architecture_descriptor"
expect_failure bash "$validator" \
  "${validation_arguments[@]/"$fixture"/"$duplicate_architecture_descriptor"}"

duplicate_digest_descriptor="$temporary_directory/duplicate-digest.json"
jq '.children[1].digest = .children[0].digest' "$fixture" > "$duplicate_digest_descriptor"
expect_failure bash "$validator" \
  "${validation_arguments[@]/"$fixture"/"$duplicate_digest_descriptor"}"

wrong_backend_metadata_descriptor="$temporary_directory/wrong-backend-metadata.json"
jq '.backend.cuda_series = "13-1"' "$fixture" > "$wrong_backend_metadata_descriptor"
expect_failure bash "$validator" \
  "${validation_arguments[@]/"$fixture"/"$wrong_backend_metadata_descriptor"}"

invalid_json_descriptor="$temporary_directory/invalid.json"
printf '{not-json\n' > "$invalid_json_descriptor"
expect_failure bash "$validator" \
  "${validation_arguments[@]/"$fixture"/"$invalid_json_descriptor"}"

expect_failure bash "$validator" \
  "${validation_arguments[@]/"$mesh_revision"/3333333333333333333333333333333333333333}"
expect_failure bash "$validator" \
  "${validation_arguments[@]/amd64,arm64/amd64}"
expect_failure bash "$validator" \
  "${validation_arguments[@]/12-9/none}"

promotion_log="$temporary_directory/promotion.log"
MOCK_DOCKER_LOG="$promotion_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
MOCK_DOCKER_RAW_MANIFEST_FILE="$raw_manifest_fixture" \
DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "$image:public-cuda12-sha-222222222222" \
    --tag "$image:public-cuda12-latest" \
    --immutable-tag \
      "$image:public-cuda12-mesh-$mesh_revision-runner-$runner_images_revision"

rg -q '^buildx imagetools inspect .*@sha256' "$promotion_log"
rg -q '^buildx imagetools create ' "$promotion_log"
if rg -q '^buildx build ' "$promotion_log"; then
  echo "promotion helper invoked an image build" >&2
  exit 1
fi

new_immutable_log="$temporary_directory/new-immutable.log"
MOCK_DOCKER_LOG="$new_immutable_log" \
MOCK_DOCKER_SOURCE_DIGEST="$digest" \
MOCK_DOCKER_MISSING_TAG_PATTERN="-mesh-" \
MOCK_DOCKER_RAW_MANIFEST_FILE="$raw_manifest_fixture" \
DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "$image:public-cuda12-sha-222222222222" \
    --immutable-tag \
      "$image:public-cuda12-mesh-$mesh_revision-runner-$runner_images_revision"
rg -q '^buildx imagetools create ' "$new_immutable_log"

immutable_conflict_log="$temporary_directory/immutable-conflict.log"
expect_failure env \
  MOCK_DOCKER_LOG="$immutable_conflict_log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  MOCK_DOCKER_TAG_DIGEST="$mismatch_digest" \
  MOCK_DOCKER_RAW_MANIFEST_FILE="$raw_manifest_fixture" \
  DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "$image:public-cuda12-sha-222222222222" \
    --immutable-tag \
      "$image:public-cuda12-mesh-$mesh_revision-runner-$runner_images_revision"
if rg -q '^buildx imagetools create ' "$immutable_conflict_log"; then
  echo "promotion continued after immutable composite tag conflict" >&2
  exit 1
fi

expect_failure env \
  MOCK_DOCKER_LOG="$temporary_directory/wrong-repository.log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  MOCK_DOCKER_RAW_MANIFEST_FILE="$raw_manifest_fixture" \
  DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "ghcr.io/mesh-llm/other:latest"

source_mismatch_log="$temporary_directory/source-mismatch.log"
expect_failure env \
  MOCK_DOCKER_LOG="$source_mismatch_log" \
  MOCK_DOCKER_SOURCE_DIGEST="$mismatch_digest" \
  MOCK_DOCKER_RAW_MANIFEST_FILE="$raw_manifest_fixture" \
  DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "$image:public-cuda12-latest"
if rg -q '^buildx imagetools create ' "$source_mismatch_log"; then
  echo "promotion continued after candidate source digest mismatch" >&2
  exit 1
fi

expect_failure env \
  MOCK_DOCKER_LOG="$temporary_directory/tag-mismatch.log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  MOCK_DOCKER_TAG_DIGEST="$mismatch_digest" \
  MOCK_DOCKER_RAW_MANIFEST_FILE="$raw_manifest_fixture" \
  DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "$image:public-cuda12-latest"

wrong_children_manifest="$temporary_directory/wrong-children-manifest.json"
jq '.manifests[1].digest = "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"' \
  "$raw_manifest_fixture" > "$wrong_children_manifest"
children_mismatch_log="$temporary_directory/children-mismatch.log"
expect_failure env \
  MOCK_DOCKER_LOG="$children_mismatch_log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  MOCK_DOCKER_RAW_MANIFEST_FILE="$wrong_children_manifest" \
  DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "$image:public-cuda12-latest"
if rg -q '^buildx imagetools create ' "$children_mismatch_log"; then
  echo "promotion continued after registry child digest mismatch" >&2
  exit 1
fi

unexpected_platform_manifest="$temporary_directory/unexpected-platform-manifest.json"
jq '.manifests += [{
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "digest": "sha256:9999999999999999999999999999999999999999999999999999999999999999",
  "size": 1000,
  "platform": {"os": "windows", "architecture": "amd64"}
}]' "$raw_manifest_fixture" > "$unexpected_platform_manifest"
unexpected_platform_log="$temporary_directory/unexpected-platform.log"
expect_failure env \
  MOCK_DOCKER_LOG="$unexpected_platform_log" \
  MOCK_DOCKER_SOURCE_DIGEST="$digest" \
  MOCK_DOCKER_RAW_MANIFEST_FILE="$unexpected_platform_manifest" \
  DOCKER_BIN="$mock_docker" \
  bash "$promoter" "${validation_arguments[@]}" \
    --tag "$image:public-cuda12-latest"
if rg -q '^buildx imagetools create ' "$unexpected_platform_log"; then
  echo "promotion continued with an unexpected runnable platform" >&2
  exit 1
fi

echo "candidate descriptor and digest promotion tests passed"
